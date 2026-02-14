#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPO="$(basename "$ROOT")"
BRANCH="factory"
FACTORY_DIR="${ROOT}/.git-factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME="factory.py"

# --- ensure .git-factory dir is ignored locally ---
DEV_MODE=false
if [[ "${1:-}" == "dev" ]]; then
  DEV_MODE=true
  shift
fi

# --- dev reset: tear down without restoring factory.sh ---
dev_reset() {
  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
  rm -rf "$FACTORY_DIR"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH" >/dev/null 2>&1 || true
  fi
  rm -f "$ROOT/factory"
}

if [[ "$DEV_MODE" == true ]] && [[ "${1:-}" == "reset" ]]; then
  dev_reset
  echo -e "\033[33mfactory:\033[0m reset"
  exit 0
fi

# --- dev mode: always start fresh ---
if [[ "$DEV_MODE" == true ]] && [[ -d "$FACTORY_DIR" ]]; then
  echo -e "\033[33mfactory:\033[0m resetting"
  dev_reset
fi

EXCLUDE_FILE="$ROOT/.git/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
touch "$EXCLUDE_FILE"
if ! grep -qxF "/.git-factory/" "$EXCLUDE_FILE"; then
  printf "\n/.git-factory/\n" >> "$EXCLUDE_FILE"
fi

# --- create factory branch if missing ---
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch "$BRANCH"
  echo -e "\033[33mfactory:\033[0m created branch $BRANCH"
fi

# --- resume existing worktree or create fresh ---
if [[ "$DEV_MODE" == false ]] && [[ -d "$WORKTREE" ]] && [[ -f "$WORKTREE/$PY_NAME" ]]; then
  echo -e "\033[33mfactory:\033[0m resuming"
  cd "$WORKTREE"
  exec python3 "$PY_NAME"
fi

# --- fresh setup: create worktree ---
mkdir -p "$FACTORY_DIR"
if [[ -d "$WORKTREE" ]]; then
  git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$WORKTREE" >/dev/null 2>&1 || true
fi
git worktree add "$WORKTREE" "$BRANCH" >/dev/null 2>&1

# --- write python runner into worktree ---
mkdir -p "$WORKTREE/tasks" "$WORKTREE/hooks" "$WORKTREE/state"
cat > "$WORKTREE/$PY_NAME" <<'PY'
#!/usr/bin/env python3
import os, sys, re, signal, time, shutil, subprocess
from pathlib import Path

signal.signal(signal.SIGINT, signal.SIG_DFL)

ROOT = Path(__file__).resolve().parent
TASKS_DIR = ROOT / "tasks"
STATE_DIR = ROOT / "state"

def log(msg):
    print(f"\033[33mfactory:\033[0m {msg}", flush=True)

def sh(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()

def require_claude():
    path = shutil.which("claude")
    if not path:
        log("claude not found on PATH")
        return None
    return path

def init():
    claude = require_claude()
    if not claude:
        return 1
    branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
    if branch != "factory":
        log(f"not on factory branch: {branch}")
        return 2
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "initialized.txt").write_text(time.ctime() + "\n")
    (STATE_DIR / "claude_path.txt").write_text(claude + "\n")
    return 0

# --- task parsing ---

def parse_task(path):
    text = path.read_text()
    if not text.startswith("---"):
        return None
    _, fm, body = text.split("---", 2)
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        meta[key.strip()] = val.strip()
    name = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", path.stem)
    return {
        "name": name,
        "tools": meta.get("tools", "Read,Write,Edit,Bash,Glob,Grep"),
        "done": meta.get("done", ""),
        "parent": meta.get("parent", ""),
        "prompt": body.strip(),
        "_path": path,
    }

def load_tasks():
    tasks = []
    if TASKS_DIR.exists():
        for f in sorted(TASKS_DIR.glob("*.md")):
            t = parse_task(f)
            if t:
                tasks.append(t)
    return tasks

def update_task_meta(task, **kwargs):
    path = task["_path"]
    text = path.read_text()
    _, fm, body = text.split("---", 2)
    lines = fm.strip().splitlines()
    existing = {}
    for i, line in enumerate(lines):
        key, _, _ = line.partition(":")
        existing[key.strip()] = i
    for key, val in kwargs.items():
        if key in existing:
            lines[existing[key]] = f"{key}: {val}"
        else:
            lines.append(f"{key}: {val}")
    path.write_text("---\n" + "\n".join(lines) + "\n---" + body)

# --- completion checks ---

def check_done(done):
    if not done:
        return False
    if done == "always":
        return False
    m = re.match(r'(\w+)\((.+)\)$', done)
    if not m:
        log(f"unknown done: {done}")
        return False
    func, raw_args = m.group(1), m.group(2)
    args = re.findall(r'"([^"]*)"', raw_args)
    if func == "section_exists":
        text = (ROOT / "CLAUDE.md").read_text() if (ROOT / "CLAUDE.md").exists() else ""
        return args[0] in text
    elif func == "no_section":
        text = (ROOT / "CLAUDE.md").read_text() if (ROOT / "CLAUDE.md").exists() else ""
        return args[0] not in text
    elif func == "file_exists":
        return (ROOT / args[0]).exists()
    elif func == "file_absent":
        return not (ROOT / args[0]).exists()
    elif func == "file_contains":
        p = ROOT / args[0]
        return p.exists() and args[1] in p.read_text()
    elif func == "file_missing_text":
        p = ROOT / args[0]
        return not p.exists() or args[1] not in p.read_text()
    elif func == "command":
        try:
            subprocess.run(args[0], shell=True, cwd=ROOT, check=True, capture_output=True)
            return True
        except subprocess.CalledProcessError:
            return False
    log(f"unknown check: {func}")
    return False

def next_task():
    tasks = load_tasks()
    done_map = {t["_path"].name: check_done(t["done"]) for t in tasks}
    for t in tasks:
        if done_map.get(t["_path"].name):
            continue
        parent = t["parent"]
        if parent and not done_map.get(parent, False):
            continue
        return t
    return None

# --- claude runner ---

def run_claude(prompt, allowed_tools="Read,Write,Edit,Bash,Glob,Grep"):
    import json as _json, threading
    claude = require_claude()
    if not claude:
        return False, None
    proc = subprocess.Popen(
        [claude, "--dangerously-skip-permissions", "-p", "--verbose",
         "--output-format", "stream-json",
         prompt, "--allowedTools", allowed_tools],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=ROOT,
    )
    session_id = None
    def read_stream():
        nonlocal session_id
        for raw in iter(proc.stdout.readline, b""):
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = _json.loads(raw)
            except ValueError:
                continue
            t = ev.get("type", "")
            if t == "assistant":
                for block in ev.get("message", {}).get("content", []):
                    if block.get("type") == "tool_use":
                        name = block.get("name", "")
                        if not name:
                            continue
                        inp = block.get("input", {})
                        detail = ""
                        if name in ("Read", "Write", "Edit"):
                            fp = inp.get("file_path", "")
                            if fp:
                                detail = fp.rsplit("/", 1)[-1]
                        elif name == "Glob":
                            detail = inp.get("pattern", "")
                        elif name == "Grep":
                            detail = inp.get("pattern", "")
                        elif name == "Bash":
                            cmd = inp.get("command", "")
                            detail = cmd[:120] + ("…" if len(cmd) > 120 else "")
                        if detail:
                            log(f"\033[36m→ {name}\033[0m \033[2m{detail}\033[0m")
                        else:
                            log(f"\033[36m→ {name}\033[0m")
            elif t == "result":
                session_id = ev.get("session_id", session_id)
                cost = ev.get("cost_usd") or ev.get("total_cost_usd")
                dur = ev.get("duration_ms")
                parts = []
                if dur:
                    parts.append(f"{dur/1000:.1f}s")
                if cost:
                    parts.append(f"${cost:.4f}")
                if parts:
                    log("\033[2m" + ", ".join(parts) + "\033[0m")
    reader = threading.Thread(target=read_stream, daemon=True)
    reader.start()
    try:
        while reader.is_alive():
            reader.join(timeout=0.1)
        return proc.wait() == 0, session_id
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        print()
        log("stopped")
        return False, session_id

# --- main loop ---

def run():
    claude = require_claude()
    if not claude:
        return

    TASKS_DIR.mkdir(exist_ok=True)
    STATE_DIR.mkdir(exist_ok=True)
    (STATE_DIR / "factory.pid").write_text(str(os.getpid()) + "\n")

    def commit_task(task, message):
        rel = task["_path"].relative_to(ROOT)
        sh("git", "add", str(rel))
        sh("git", "commit", "-m", message)

    while True:
        task = next_task()
        if task is None:
            log("idle — waiting for tasks")
            while next_task() is None:
                time.sleep(5)
            continue
        name = task["name"]
        log(f"task: {name}")
        branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
        update_task_meta(task, pid=str(os.getpid()), branch=branch)
        commit_task(task, f"Start Task: {name}")
        ok, session_id = run_claude(task["prompt"], allowed_tools=task["tools"])
        if session_id:
            update_task_meta(task, session=session_id)
        if not ok:
            commit_task(task, f"Failed Task: {name}")
            log(f"task failed: {name}")
            return
        if check_done(task["done"]):
            try:
                commit = sh("git", "rev-parse", "HEAD")
                update_task_meta(task, commit=commit)
            except Exception:
                pass
            commit_task(task, f"Complete Task: {name}")
            log(f"task done: {name}")
        else:
            commit_task(task, f"Incomplete Task: {name}")
            log(f"task did not complete: {name}")
            return

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        raise SystemExit(init())
    run()
PY
chmod +x "$WORKTREE/$PY_NAME"

# --- write CLAUDE.md (metadata only) ---
cat > "$WORKTREE/CLAUDE.md" <<CLAUDE
# Factory

Automated software factory for \`$REPO\`.

Source repo: \`$ROOT\`
Worktree: \`$WORKTREE\`
Runner: \`factory.py\`
Tasks: \`tasks/\`
State: \`state/\`

You are a coding agent operating inside a git worktree on the \`factory\` branch.
The source codebase lives at \`$ROOT\` — you can read it but must not write to it directly.
All your work happens here in the worktree.

**Important**: Never read or traverse into the \`.git-factory/\` directory in the source repo.
It contains the factory runtime and is not part of the codebase.

## How tasks work

You are given one task at a time by the runner (\`factory.py\`). The task prompt
is your entire instruction for that run. You MUST follow these rules:

1. **Do the task.** Complete what the task prompt asks.
2. **Commit your work.** When you are done, \`git add\` and \`git commit\` the
   files you changed. Use a short, descriptive commit message that summarizes
   what you did — not the task name, not a prefix, just what changed.
3. **Creating tasks.** Tasks are markdown files in \`tasks/\` with YAML
   frontmatter. If your task creates follow-up tasks, you MUST set the
   \`parent\` field to the filename of the current task so the runner knows
   the dependency order. Use the naming convention \`YYYY-MM-DD-slug.md\`.
4. **Do not modify this file beyond what a task asks.** If a task tells you to
   add sections to \`CLAUDE.md\`, do that. Otherwise leave it alone.
5. **Stop when done.** Do not loop, do not start the next task, do not look
   for more work. Complete your task, commit, and stop.
CLAUDE

# --- write bootstrap task ---
cat > "$WORKTREE/tasks/$(date +%Y-%m-%d)-define-purpose.md" <<'TASK'
---
tools: Read,Write,Edit,Bash
done: section_exists("## Purpose")
---

Read `CLAUDE.md` in this directory, then read the source repo's `CLAUDE.md`
and `README.md` (if they exist). The source repo path is in the CLAUDE.md
header.

Your task is to add three sections to this worktree's CLAUDE.md: **Purpose**,
**Measures**, and **Tests**.

Each section has three levels of abstraction: **Operational**, **Strategic**,
and **Existential**.

- **Operational** — what to improve next in this repository.
- **Strategic** — what kinds of improvements compound over time.
- **Existential** — what kind of system this repository should become long-term.

Keep all three levels concrete and software-focused. No philosophical or
societal framing. Ground everything in what you observe in the actual repo.

Bullet counts should expand as you move down the ladder:
- Existential subsections: 3-5 bullets.
- Strategic subsections: 5-10 bullets.
- Operational subsections: 10-20 bullets.

---

## Purpose

The Purpose section defines what "better" means for this codebase.

**Existential Purpose** (3-5 bullets) — Define why this software exists in
terms of the real-world outcome it produces. What is true for its users or its
domain when this software is succeeding? If it's a tool for nurses: "Nurses
spend more time with patients and less time on paperwork." If it's a developer
tool: "Developers ship changes confidently with fewer manual steps." If it's an
automation system: "Routine decisions happen without human intervention." Keep
it concrete and tied to the people or problem the software serves. Do not
describe the character of the codebase here — that belongs in strategic purpose.

**Strategic Purpose** (5-10 bullets) — Define medium-term direction tied to
what you observe in the repo. Examples: reduce complexity in core paths,
improve developer ergonomics, prefer explicitness over magic, strengthen
invariants and contracts, eliminate sources of brittleness.

**Operational Purpose** (10-20 bullets) — Define immediate, repo-specific
priorities. Be concrete and name areas of the repo. Examples: simplify a
confusing module, remove dead code, reduce test flakiness, improve error
messages, clarify public APIs, reduce steps to run locally.

---

## Measures

The Measures section defines signals of progress. Every measure must include
how it is observed — a command, a metric, or a concrete thing you can point at.

**Existential Measures** (3-5 bullets) — Indicators that the software is
fulfilling its reason for existing. These are not about code health — they are
about the real-world outcome the system was built to produce. If the repo is a
tool for healthcare nurses, examples might be: nurses spend less time on
charting, fewer tasks require manual data entry, shift handoffs take less time.
If it's a developer tool: developers ship faster, debugging takes fewer steps,
onboarding a new team member is easier. Tie these directly to the existential
purpose — what would be true in the world if this software were succeeding?

**Strategic Measures** (5-10 bullets) — Medium-term progress signals. Examples:
reduced complexity in core modules, faster test runs, fewer build steps,
clearer documentation, less coupling between subsystems.

**Operational Measures** (10-20 bullets) — Concrete, checkable signals tied
directly to the operational purpose. Each one should answer: "How do I know
this specific thing got better?" Examples: tests pass, lint clean, CI time
decreased by N seconds, fewer TODOs in module X, setup runs in fewer steps,
error message for Y now tells the user what to do, endpoint Z responds in
under N ms.

---

## Tests

The Tests section contains "purpose gate" questions. Ask yourself these
questions every time you make a change.

**Existential Tests** (3-5 bullets) — Does this change move the needle on the
real-world outcome the software exists to produce? Does it make the user's life
concretely better? Would the person this software serves notice or care about
this change? Does it bring the system closer to fulfilling its reason for
existing?

**Strategic Tests** (5-10 bullets) — Does this compound future improvements?
Does it reduce brittleness? Does it remove duplication? Does it improve
clarity in the most-used paths?

**Operational Tests** (10-20 bullets) — Specific, answerable questions about
immediate outcomes. These should reference concrete commands, user actions, and
the operational purpose and measures directly. Examples:

- What commands did you run to verify this works?
- Do all tests pass? Which test suites did you run?
- Does this make it easier for a user to [specific action]?
- Does this make [specific operation] faster or more reliable?
- Is the diff minimal for the behavior change achieved?
- Does this satisfy [specific operational purpose item] according to
  [specific operational measure]?
- Did you check that [specific thing] did not regress?
- Can a new contributor understand this change without extra context?
- Does the error output tell the user what went wrong and what to do?

After writing these sections, add them to this worktree's CLAUDE.md.

Once that's done you should have a clear understanding of the repo's purpose and
must now write the best next task for improving the repo based on that purpose.
DO NOT USE THIS TASK THE PARENT OF YOUR NEXT TASK. This task is just to get the
purpose defined and should not be a dependency for future work.

TASK

# --- copy .gitignore from source repo ---
if [[ -f "$ROOT/.gitignore" ]]; then
  cp "$ROOT/.gitignore" "$WORKTREE/.gitignore"
fi

# --- ignore state/ in worktree ---
WORKTREE_GITIGNORE="$WORKTREE/.gitignore"
if [[ ! -f "$WORKTREE_GITIGNORE" ]] || ! grep -qxF "state/" "$WORKTREE_GITIGNORE"; then
  printf "\nstate/\n" >> "$WORKTREE_GITIGNORE"
fi

# --- install post-commit hook for worktree ---
cat > "$WORKTREE/hooks/post-commit" <<'HOOK'
#!/usr/bin/env bash
echo -e "\033[33mfactory:\033[0m NEW COMMIT"
HOOK
chmod +x "$WORKTREE/hooks/post-commit"
git -C "$WORKTREE" config core.hooksPath hooks

# --- copy original installer into worktree and commit ---
cp "$0" "$WORKTREE/factory.sh"
TASK_FILE="$(ls "$WORKTREE/tasks/"*.md 2>/dev/null | head -1)"
TASK_NAME="$(basename "$TASK_FILE" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')"
(
  cd "$WORKTREE"
  git add -f .gitignore CLAUDE.md "$PY_NAME" factory.sh hooks/
  git commit -m "Bootstrap" >/dev/null 2>&1 || true
  git add -f tasks/
  git commit -m "New Task: $TASK_NAME" >/dev/null 2>&1 || true
)

# --- init ---
(
  cd "$WORKTREE"
  python3 "$PY_NAME" init
) || { echo -e "\033[33mfactory:\033[0m init failed — aborting"; git worktree remove --force "$WORKTREE" 2>/dev/null || true; exit 1; }

# --- replace this installer with a launcher script (skip in dev mode) ---
if [[ "$DEV_MODE" == true ]]; then
  echo -e "\033[33mfactory:\033[0m dev mode — worktree at .git-factory/worktree"
  cd "$WORKTREE"
  exec python3 "$PY_NAME"
fi

SCRIPT_PATH="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0")"
LAUNCHER="$ROOT/factory"
if [[ "$SCRIPT_PATH" == "$ROOT"* ]] && [[ "$SCRIPT_PATH" != "$LAUNCHER" ]]; then
  rm -f "$SCRIPT_PATH" || true
fi
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
FACTORY_DIR="${ROOT}/.git-factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME="factory.py"

if [[ "${1:-}" == "destroy" ]]; then
  echo "This will permanently remove:"
  echo "  - .git-factory/ (worktree + state)"
  echo "  - factory branch"
  echo "  - ./factory launcher"
  echo ""
  printf "Type 'yes' to confirm: "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    echo -e "\033[33mfactory:\033[0m destroy cancelled"
    exit 1
  fi

  # restore factory.sh from the worktree commit before destroying
  if [[ -f "$WORKTREE/factory.sh" ]]; then
    cp "$WORKTREE/factory.sh" "$ROOT/factory.sh"
    echo -e "\033[33mfactory:\033[0m restored factory.sh"
  fi

  # remove worktree then .git-factory dir
  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
  rm -rf "$FACTORY_DIR"
  echo -e "\033[33mfactory:\033[0m removed .git-factory/"

  # delete factory branches
  if git show-ref --verify --quiet "refs/heads/factory"; then
    git branch -D factory >/dev/null 2>&1 || true
    echo -e "\033[33mfactory:\033[0m deleted 'factory' branch"
  fi

  # remove this launcher
  rm -f "$ROOT/factory"
  echo -e "\033[33mfactory:\033[0m destroyed"
  exit 0
fi

cd "$WORKTREE"
exec python3 "$PY_NAME"
LAUNCH
chmod +x "$LAUNCHER"

# --- ignore the launcher via .git/info/exclude ---
if ! grep -qxF "/factory" "$EXCLUDE_FILE"; then
  printf "\n/factory\n" >> "$EXCLUDE_FILE"
fi

echo -e "\033[33mfactory:\033[0m worktree at .git-factory/worktree"
echo -e "\033[33mfactory:\033[0m run ./factory to start"

# --- run in foreground so user sees output ---
cd "$WORKTREE"
exec python3 "$PY_NAME"
