#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPO="$(basename "$ROOT")"
BRANCH="factory"
FACTORY_DIR="${ROOT}/.factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME=".factory/factory.py"

# --- ensure .factory dir is ignored locally ---
EXCLUDE_FILE="$ROOT/.git/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
touch "$EXCLUDE_FILE"
if ! grep -qxF "/.factory/" "$EXCLUDE_FILE"; then
  printf "\n/.factory/\n" >> "$EXCLUDE_FILE"
fi

# --- create factory branch if missing ---
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch "$BRANCH"
  echo "factory: created branch $BRANCH"
fi

# --- resume existing worktree or create fresh ---
if [[ -d "$WORKTREE" ]] && [[ -f "$WORKTREE/$PY_NAME" ]]; then
  echo "factory: resuming"
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
mkdir -p "$WORKTREE/.factory"
cat > "$WORKTREE/$PY_NAME" <<'PY'
#!/usr/bin/env python3
import os, sys, signal, time, shutil, subprocess
from pathlib import Path

signal.signal(signal.SIGINT, lambda *_: (print("\rfactory: stopped"), sys.exit(0)))

ROOT = Path(__file__).resolve().parents[1]
FACTORY = ROOT / ".factory"

def sh(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()

def require_claude():
    """Return path to claude CLI, or None if not found."""
    path = shutil.which("claude")
    if not path:
        print("factory: claude not found on PATH")
        return None
    return path

def init():
    claude = require_claude()
    if not claude:
        return 1

    branch = sh("git","rev-parse","--abbrev-ref","HEAD")
    if branch != "factory":
        print("factory: not on factory branch:", branch)
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

def run_claude(prompt):
    claude = require_claude()
    if not claude:
        return False
    proc = subprocess.Popen(
        [claude, "-p", prompt, "--allowedTools", "Read,Write,Edit,Bash,Glob,Grep"],
        cwd=ROOT,
    )
    try:
        return proc.wait() == 0
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait()
        print("\rfactory: stopped")
        sys.exit(0)

def run():
    claude = require_claude()
    if not claude:
        return

    FACTORY.mkdir(exist_ok=True)
    (FACTORY / "factory.pid").write_text(str(os.getpid()) + "\n")

    if needs_bootstrap():
        print("factory: bootstrapping — reviewing source repo")
        ok = run_claude(
            "Read the CLAUDE.md in this directory. It contains a Bootstrap section "
            "with instructions for your first task. Follow those instructions exactly."
        )
        if not ok:
            print("factory: bootstrap failed")
            return
        print("factory: bootstrap complete")

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

# --- write bootstrap CLAUDE.md ---
cat > "$WORKTREE/CLAUDE.md" <<CLAUDE
# Factory

Automated software factory for \`$REPO\`.

Source repo: \`$ROOT\`
Worktree: \`$WORKTREE\`
Runner: \`.factory/factory.py\`
State: \`.factory/state/\`

You are a coding agent operating inside a git worktree on the \`factory\` branch.
The source codebase lives at \`$ROOT\` — you can read it but must not write to it directly.
All your work happens here in the worktree.

**Important**: Never read or traverse into any \`.factory/\` directory in the source repo
or this worktree. It contains the factory runtime and is not part of the codebase.

## Bootstrap
Your first task is to review the source repo and replace the Bootstrap section
in this CLAUDE.md file with three sections: **Purpose**, **Measures**, and
**Tests**. These sections will guide all future work, so write them carefully.

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
cp "$0" "$WORKTREE/.factory/factory.sh"
(
  cd "$WORKTREE"
  git add -f CLAUDE.md "$PY_NAME" .factory/factory.sh
  git commit -m "factory: bootstrap" >/dev/null 2>&1 || true
)

# --- init ---
(
  cd "$WORKTREE"
  python3 "$PY_NAME" init
) || { echo "factory: init failed — aborting"; git worktree remove --force "$WORKTREE" 2>/dev/null || true; exit 1; }

# --- replace this installer with a launcher script ---
SCRIPT_PATH="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0")"
LAUNCHER="$ROOT/factory"
if [[ "$SCRIPT_PATH" == "$ROOT"* ]] && [[ "$SCRIPT_PATH" != "$LAUNCHER" ]]; then
  rm -f "$SCRIPT_PATH" || true
fi
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
FACTORY_DIR="${ROOT}/.factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME=".factory/factory.py"

if [[ "${1:-}" == "destroy" ]]; then
  echo "This will permanently remove:"
  echo "  - .factory/ (worktree + state)"
  echo "  - factory branch"
  echo "  - ./factory launcher"
  echo ""
  printf "Type 'yes' to confirm: "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "factory: destroy cancelled"
    exit 1
  fi

  # restore factory.sh from the worktree commit before destroying
  if [[ -f "$WORKTREE/.factory/factory.sh" ]]; then
    cp "$WORKTREE/.factory/factory.sh" "$ROOT/factory.sh"
    echo "factory: restored factory.sh"
  fi

  # remove worktree then .factory dir
  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
  rm -rf "$FACTORY_DIR"
  echo "factory: removed .factory/"

  # delete factory branches
  if git show-ref --verify --quiet "refs/heads/factory"; then
    git branch -D factory >/dev/null 2>&1 || true
    echo "factory: deleted 'factory' branch"
  fi

  # remove this launcher
  rm -f "$ROOT/factory"
  echo "factory: destroyed"
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

echo "factory: worktree at .factory/worktree"
echo "factory: run ./factory to start"

# --- run in foreground so user sees output ---
cd "$WORKTREE"
exec python3 "$PY_NAME"
