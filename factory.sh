#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPO="$(basename "$ROOT")"
BRANCH="factory"
FACTORY_DIR="${ROOT}/.git-factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME=".git-factory/factory.py"

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

# --- write minimal python runner into worktree ---
mkdir -p "$WORKTREE/.git-factory"
cat > "$WORKTREE/$PY_NAME" <<'PY'
#!/usr/bin/env python3
import os, sys, signal, time, shutil, subprocess
from pathlib import Path

signal.signal(signal.SIGINT, signal.SIG_DFL)

ROOT = Path(__file__).resolve().parents[1]
FACTORY = ROOT / ".git-factory"

def log(msg):
    print(f"\033[33mfactory:\033[0m {msg}", flush=True)

def sh(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()

def require_claude():
    """Return path to claude CLI, or None if not found."""
    path = shutil.which("claude")
    if not path:
        log("claude not found on PATH")
        return None
    return path

def init():
    claude = require_claude()
    if not claude:
        return 1

    branch = sh("git","rev-parse","--abbrev-ref","HEAD")
    if branch != "factory":
        log(f"not on factory branch: {branch}")
        return 2

    (FACTORY / "state").mkdir(parents=True, exist_ok=True)
    (FACTORY / "state" / "initialized.txt").write_text(time.ctime() + "\n")
    (FACTORY / "state" / "claude_path.txt").write_text(claude + "\n")
    return 0

def needs_bootstrap():
    claude_md = ROOT / "CLAUDE.md"
    if not claude_md.exists():
        return True
    return "## Bootstrap" in claude_md.read_text()

def run_claude(prompt, allowed_tools="Read,Write,Edit,Bash,Glob,Grep"):
    import json as _json, threading
    claude = require_claude()
    if not claude:
        return False
    proc = subprocess.Popen(
        [claude, "--dangerously-skip-permissions", "-p", "--verbose",
         "--output-format", "stream-json",
         prompt, "--allowedTools", allowed_tools],
        stdout=subprocess.PIPE,
        cwd=ROOT,
    )
    def read_stream():
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
                            detail = cmd[:60] + ("…" if len(cmd) > 60 else "")
                        if detail:
                            log(f"\033[36m→ {name}\033[0m \033[2m{detail}\033[0m")
                        else:
                            log(f"\033[36m→ {name}\033[0m")
            elif t == "result":
                cost = ev.get("total_cost_usd")
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
        return proc.wait() == 0
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        log("stopped")
        return False

def run():
    claude = require_claude()
    if not claude:
        return

    FACTORY.mkdir(exist_ok=True)
    (FACTORY / "factory.pid").write_text(str(os.getpid()) + "\n")

    if needs_bootstrap():
        log("bootstrapping — reviewing source repo")
        ok = run_claude(
            "Read the CLAUDE.md in this directory. It contains a Bootstrap section "
            "with instructions for your first task. Follow those instructions exactly. "
            "All source code is already provided in the CLAUDE.md — do not explore the "
            "source repo yourself. Just read CLAUDE.md, then write the replacement.",
            allowed_tools="Read,Write,Edit,Bash"
        )
        if not ok:
            log("bootstrap failed")
            return
        log("bootstrap complete")

    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    i = 0
    while True:
        print(f"\rfactory: {frames[i % len(frames)]}", end="", flush=True)
        i += 1
        time.sleep(0.08)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        raise SystemExit(init())
    run()
PY
chmod +x "$WORKTREE/$PY_NAME"

# --- snapshot source repo for bootstrap context ---
SNAPSHOT="$(
  echo '```'
  echo "## File tree"
  git ls-tree -r --name-only HEAD | grep -v '^\.' | head -100
  echo ""
  echo "## Commit history (last 500)"
  git log --oneline -500
  echo '```'
)"

# --- read all source files (non-binary, non-dot, <50KB) into a block ---
SOURCE_CONTENTS="$(
  echo '```'
  git ls-tree -r --name-only HEAD | grep -v '^\.' | while read -r f; do
    if [[ -f "$ROOT/$f" ]] && file -b --mime "$ROOT/$f" | grep -q 'text/' && [[ $(stat -f%z "$ROOT/$f" 2>/dev/null || stat -c%s "$ROOT/$f" 2>/dev/null) -lt 51200 ]]; then
      echo "=== $f ==="
      cat "$ROOT/$f"
      echo ""
    fi
  done
  echo '```'
)"

# --- write bootstrap CLAUDE.md ---
cat > "$WORKTREE/CLAUDE.md" <<CLAUDE
# Factory

Automated software factory for \`$REPO\`.

Source repo: \`$ROOT\`
Worktree: \`$WORKTREE\`
Runner: \`.git-factory/factory.py\`
State: \`.git-factory/state/\`

You are a coding agent operating inside a git worktree on the \`factory\` branch.
The source codebase lives at \`$ROOT\` — you can read it but must not write to it directly.
All your work happens here in the worktree.

**Important**: Never read or traverse into any \`.git-factory/\` directory in the source repo
or this worktree. It contains the factory runtime and is not part of the codebase.

## Source Repo Snapshot

Everything you need to know about the source repo is below. **Do NOT explore
the source repo yourself** — do not run find, ls, cat, git log, git show, or
any other discovery commands against it. Use only what is provided here.

$SNAPSHOT

### Source File Contents

$SOURCE_CONTENTS

## Bootstrap

Your first task is to replace everything from \`## Source Repo Snapshot\` to the
end of this file with three sections: **Purpose**, **Measures**, and **Tests**.
Base your analysis entirely on the snapshot above. Do not explore the source repo.

Each section has three levels of abstraction: **Operational**, **Strategic**,
and **Existential**.

- **Operational** — what to improve next in this repository.
- **Strategic** — what kinds of improvements compound over time.
- **Existential** — what kind of system this repository should become long-term.

Keep all three levels concrete and software-focused. No philosophical or
societal framing. Ground everything in what you observe in the actual repo.

Bullet counts should expand as you move down the ladder:
- Existential subsections: 3–5 bullets.
- Strategic subsections: 5–10 bullets.
- Operational subsections: 10–20 bullets.

---

## Purpose

The Purpose section defines what "better" means for this codebase.

**Existential Purpose** (3–5 bullets) — Define why this software exists in
terms of the real-world outcome it produces. What is true for its users or its
domain when this software is succeeding? If it's a tool for nurses: "Nurses
spend more time with patients and less time on paperwork." If it's a developer
tool: "Developers ship changes confidently with fewer manual steps." If it's an
automation system: "Routine decisions happen without human intervention." Keep
it concrete and tied to the people or problem the software serves. Do not
describe the character of the codebase here — that belongs in strategic purpose.

**Strategic Purpose** (5–10 bullets) — Define medium-term direction tied to
what you observe in the repo. Examples: reduce complexity in core paths,
improve developer ergonomics, prefer explicitness over magic, strengthen
invariants and contracts, eliminate sources of brittleness.

**Operational Purpose** (10–20 bullets) — Define immediate, repo-specific
priorities. Be concrete and name areas of the repo. Examples: simplify a
confusing module, remove dead code, reduce test flakiness, improve error
messages, clarify public APIs, reduce steps to run locally.

---

## Measures

The Measures section defines signals of progress. Every measure must include
how it is observed — a command, a metric, or a concrete thing you can point at.

**Existential Measures** (3–5 bullets) — Indicators that the software is
fulfilling its reason for existing. These are not about code health — they are
about the real-world outcome the system was built to produce. If the repo is a
tool for healthcare nurses, examples might be: nurses spend less time on
charting, fewer tasks require manual data entry, shift handoffs take less time.
If it's a developer tool: developers ship faster, debugging takes fewer steps,
onboarding a new team member is easier. Tie these directly to the existential
purpose — what would be true in the world if this software were succeeding?

**Strategic Measures** (5–10 bullets) — Medium-term progress signals. Examples:
reduced complexity in core modules, faster test runs, fewer build steps,
clearer documentation, less coupling between subsystems.

**Operational Measures** (10–20 bullets) — Concrete, checkable signals tied
directly to the operational purpose. Each one should answer: "How do I know
this specific thing got better?" Examples: tests pass, lint clean, CI time
decreased by N seconds, fewer TODOs in module X, setup runs in fewer steps,
error message for Y now tells the user what to do, endpoint Z responds in
under N ms.

---

## Tests

The Tests section contains "purpose gate" questions. Ask yourself these
questions every time you make a change.

**Existential Tests** (3–5 bullets) — Does this change move the needle on the
real-world outcome the software exists to produce? Does it make the user's life
concretely better? Would the person this software serves notice or care about
this change? Does it bring the system closer to fulfilling its reason for
existing?

**Strategic Tests** (5–10 bullets) — Does this compound future improvements?
Does it reduce brittleness? Does it remove duplication? Does it improve
clarity in the most-used paths?

**Operational Tests** (10–20 bullets) — Specific, answerable questions about
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

After writing these sections, commit this file with the message
\`factory: describe source repo purpose and goals\`.
CLAUDE

# --- copy original installer into worktree and commit ---
cp "$0" "$WORKTREE/.git-factory/factory.sh"
(
  cd "$WORKTREE"
  git add -f CLAUDE.md "$PY_NAME" .git-factory/factory.sh
  git commit -m "factory: bootstrap" >/dev/null 2>&1 || true
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
PY_NAME=".git-factory/factory.py"

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
  if [[ -f "$WORKTREE/.git-factory/factory.sh" ]]; then
    cp "$WORKTREE/.git-factory/factory.sh" "$ROOT/factory.sh"
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
