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
        log(f"skipping {path.name}: no frontmatter")
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        log(f"skipping {path.name}: malformed frontmatter")
        return None
    _, fm, body = parts
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        if key.strip():
            meta[key.strip()] = val.strip()
    # parse sections from body
    sections = {}
    current_section = None
    current_lines = []
    prompt_lines = []
    for line in body.split("\n"):
        m = re.match(r'^##\s+(.+)$', line)
        if m:
            if current_section:
                sections[current_section] = "\n".join(current_lines).strip()
            current_section = m.group(1).strip().lower()
            current_lines = []
        elif current_section:
            current_lines.append(line)
        else:
            prompt_lines.append(line)
    if current_section:
        sections[current_section] = "\n".join(current_lines).strip()
    # extract done conditions from ## Done section
    done_lines = []
    if "done" in sections:
        for line in sections["done"].splitlines():
            line = line.strip().lstrip("- ")
            if line and re.match(r'`?(\w+)\(', line):
                done_lines.append(line.strip('`'))
            elif line == "always" or line == "`always`":
                done_lines.append("always")
    name = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", path.stem)
    return {
        "name": name,
        "tools": meta.get("tools", "Read,Write,Edit,Bash,Glob,Grep"),
        "done": done_lines,
        "parent": meta.get("parent", ""),
        "prompt": "\n".join(prompt_lines).strip(),
        "sections": sections,
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

def check_one_condition(cond):
    if not cond:
        return False
    if cond == "always":
        return False
    m = re.match(r'(\w+)\((.+)\)$', cond)
    if not m:
        log(f"unknown condition: {cond}")
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

def check_done(done):
    """Check a list of done conditions. All must pass."""
    if not done:
        return False
    return all(check_one_condition(c) for c in done)

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

# --- task planning ---

PLAN_PROMPT = """\
You are the factory's planning agent. Your only job right now is to decide
what the single best next task is and write it as a task file.

## Step 1: Understand where things stand

Read this worktree's `CLAUDE.md` — specifically the Purpose, Measures, and
Tests sections. These define what "better" means for this repo.

Then review `tasks/` to understand what has already been done (completed
tasks), what was attempted but didn't finish (incomplete/failed tasks), and
what patterns have emerged.

Then read the source repo to understand the current state of the actual code.
Look at the structure, the quality, the gaps. Don't just skim — read enough
to form a real opinion about what matters most right now.

## Step 2: Decide what to do next

Pick the single highest-leverage improvement. Use these criteria:

1. **Purpose alignment** — Does it directly advance an item in the
   Operational Purpose? Does it move a needle described in Measures?
2. **Foundation first** — Prefer work that unblocks or compounds future
   work. Tests before features. Structure before polish. Contracts before
   implementations.
3. **Concreteness** — The task must name specific files, functions, or
   behaviors. "Improve error handling" is too vague. "Add error context to
   the parse_task function when YAML frontmatter is malformed" is concrete.
4. **Right-sized** — A single task should be completable in one agent
   session. If the improvement is large, find the smallest slice that
   delivers value on its own.
5. **No repetition** — Don't redo work that's already been completed.
   Check completed tasks carefully. Don't create a task that duplicates
   or overlaps with an existing one.
6. **Don't plan ahead** — Write exactly one task. Don't create a backlog.
   The factory will call you again when this task is done.

## Step 3: Write the task file

Create a file in `tasks/` named `{today}-slug.md` where `{today}` is today's
date (YYYY-MM-DD format) and `slug` is a short kebab-case description.

Follow the task format documented in `CLAUDE.md`. Include:

- **Frontmatter** with `tools` (only the tools the task actually needs).
- **Prompt body** — Clear, specific instructions. Name files and functions.
  Describe the desired behavior, not just "fix" or "improve".
- **`## Done`** — Concrete completion conditions the runner can verify
  mechanically. Use the condition types from CLAUDE.md. Every task must
  be verifiable without human judgment.
- **`## Context`** — Why this task matters. Reference specific items from
  Purpose, Measures, or Tests. This helps the executing agent understand
  the "why" and make better judgment calls.
- **`## Verify`** — How the executing agent should check its own work
  before committing. Concrete commands, files to inspect, behaviors to
  confirm.

After writing the task file, `git add` and `git commit` it with the message
`New Task: <slug>` where `<slug>` is the task name.

Do NOT set a `parent` field unless the task genuinely depends on another
task that hasn't completed yet.

Write one task, commit it, and stop.
"""

def plan_next_task():
    today = time.strftime("%Y-%m-%d")
    prompt = PLAN_PROMPT.replace("{today}", today)
    log("planning next task")
    ok, session_id = run_claude(prompt)
    if ok:
        log("task planned")
    else:
        log("planning failed")
    return ok

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
            if not plan_next_task():
                log("stopping — planning failed")
                return
            continue
        name = task["name"]
        log(f"task: {name}")
        branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
        update_task_meta(task, status="active", pid=str(os.getpid()), branch=branch)
        commit_task(task, f"Start Task: {name}")
        # build prompt: instruction body + context + verify (exclude done)
        prompt_parts = [task["prompt"]]
        for section in ("context", "verify"):
            if section in task["sections"]:
                prompt_parts.append(f"## {section.title()}\n\n{task['sections'][section]}")
        prompt = "\n\n".join(prompt_parts)
        ok, session_id = run_claude(prompt, allowed_tools=task["tools"])
        if session_id:
            update_task_meta(task, session=session_id)
        if not ok:
            update_task_meta(task, status="failed")
            commit_task(task, f"Failed Task: {name}")
            log(f"task failed: {name}")
            return
        if check_done(task["done"]):
            commit = sh("git", "rev-parse", "HEAD")
            update_task_meta(task, status="completed", commit=commit)
            commit_task(task, f"Complete Task: {name}")
            log(f"task done: {name}")
        else:
            update_task_meta(task, status="incomplete")
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
3. **Do not modify this file beyond what a task asks.** If a task tells you to
   add sections to \`CLAUDE.md\`, do that. Otherwise leave it alone.
4. **Stop when done.** Do not loop, do not start the next task, do not look
   for more work. Complete your task, commit, and stop.

## Task format

Tasks are markdown files in \`tasks/\` named \`YYYY-MM-DD-slug.md\`. Every task
has YAML frontmatter for runner metadata, then a fixed set of markdown sections.

\`\`\`markdown
---
tools: Read,Write,Edit,Bash
parent: YYYY-MM-DD-other-task.md
---

What to do. This is the prompt — the agent's instruction for this run.
Be specific and concrete. Name files, functions, and behaviors.

## Done

Completion conditions checked by the runner after the agent finishes.
One condition per line. All must pass. Supported conditions:

- \\\`section_exists("text")\\\` — text appears in CLAUDE.md
- \\\`file_exists("path")\\\` — file exists in the worktree
- \\\`file_absent("path")\\\` — file does not exist
- \\\`file_contains("path", "text")\\\` — file contains text
- \\\`file_missing_text("path", "text")\\\` — file missing or lacks text
- \\\`command("cmd")\\\` — shell command exits 0
- \\\`always\\\` — task never completes (recurring)

## Context

Why this task exists. What purpose or measure it serves. Link to specific
items in the Purpose, Measures, or Tests sections of CLAUDE.md so the
agent understands how this work connects to the repo's goals.

## Verify

How the agent should check its own work before committing. Concrete
commands to run, files to inspect, behaviors to confirm. The agent
should do these checks — they are instructions, not just documentation.
\`\`\`

### Frontmatter fields

Author-set fields:

- **tools** — which Claude Code tools the agent can use (default:
  \`Read,Write,Edit,Bash,Glob,Grep\`)
- **parent** — filename of a task that must complete first (dependency)

Runner-managed fields (set automatically, do not write these yourself):

- **status** — lifecycle state: \`active\`, \`completed\`, \`failed\`, \`incomplete\`
- **pid** — process ID of the runner
- **session** — Claude session ID
- **branch** — git branch the task ran on
- **commit** — HEAD commit hash when the task completed

### Creating follow-up tasks

If your task creates follow-up tasks, set the \`parent\` field in the new
task's frontmatter to the filename of the current task so the runner
knows the dependency order.
CLAUDE

# --- write bootstrap task ---
cat > "$WORKTREE/tasks/$(date +%Y-%m-%d)-define-purpose.md" <<'TASK'
---
tools: Read,Write,Edit,Bash
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

### Purpose

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

### Measures

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

### Tests

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

## Done

- `section_exists("## Purpose")`

## Context

This is the bootstrap task. It creates the Purpose, Measures, and Tests
sections that guide all future factory work. Without these sections, the
agent has no way to evaluate whether a change is worthwhile.

## Verify

- Confirm `CLAUDE.md` contains `## Purpose`, `## Measures`, and `## Tests`
  sections with Existential, Strategic, and Operational subsections.
- Confirm each subsection has the right number of bullets (3-5 existential,
  5-10 strategic, 10-20 operational).
- Read the sections back and check they are grounded in the actual repo, not
  generic platitudes.
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
