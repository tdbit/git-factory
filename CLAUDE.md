# git-factory

Autonomous software factory that embeds a Claude Code agent inside a git repo. A developer drops `factory.sh` into any repo, runs it once, and an AI agent bootstraps itself into an isolated git worktree where it continuously analyzes, plans, and improves the codebase.

## Quick reference

```bash
bash factory.sh              # first run: bootstrap
./factory                    # resume
bash factory.sh dev          # dev mode: reset + bootstrap + run
bash factory.sh dev reset    # tear down only
./factory destroy            # remove everything, restore factory.sh
```

## Architecture

Everything lives in a single file: `factory.sh` (bash installer + embedded Python runner). No external dependencies beyond `claude` (or `claude-code`), `git`, `python3`, and `bash`.

- `factory.sh` creates a `factory` branch and a git worktree at `.git-factory/worktree/`
- The embedded Python runner (`factory.py`) is extracted into the worktree
- The agent works on the `factory` branch only — the source working tree is never touched
- `.git-factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files)
- After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

### Key paths (at runtime)

| Path | What |
|---|---|
| `factory.sh` | One-shot installer (replaced by `./factory` after first run) |
| `.git-factory/worktree/` | Git worktree on the `factory` branch |
| `.git-factory/worktree/factory.py` | Python orchestrator |
| `.git-factory/worktree/CLAUDE.md` | Agent's operating instructions (Purpose/Measures/Tests) |
| `.git-factory/worktree/tasks/` | Task queue (markdown files with YAML frontmatter) |
| `.git-factory/worktree/state/` | Runtime state (pid, claude path, init timestamp) |

## Code layout

`factory.sh` is structured as:

1. **Bash preamble** — arg parsing, dev mode, dev reset
2. **Worktree setup** — branch creation, worktree creation, resume logic
3. **Embedded Python** (`cat > ... <<'PY'`) — the full `factory.py` runner:
   - Task parsing (`parse_task`, `load_tasks`)
   - Task metadata updates (`update_task_meta`)
   - Completion checks (`check_one_condition`, `check_done`)
   - Task scheduling (`next_task`)
   - Claude headless runner (`run_claude`) — streams JSON, logs tool calls
   - Main loop (`run`) — picks next task, runs agent, commits results
4. **CLAUDE.md template** — written into the worktree
5. **Bootstrap task** — the `define-purpose` task template
6. **Post-setup** — gitignore copying, hook installation, launcher generation

## Task system

Tasks are markdown files in `tasks/` named `YYYY-MM-DD-slug.md`. Each has YAML frontmatter (`tools`, `parent`) and markdown sections (`## Done`, `## Context`, `## Verify`).

### Completion conditions (in `## Done`)

| Condition | Passes when |
|---|---|
| `section_exists("text")` | text appears in worktree `CLAUDE.md` |
| `no_section("text")` | text does not appear in worktree `CLAUDE.md` |
| `file_exists("path")` | file exists in the worktree |
| `file_absent("path")` | file does not exist |
| `file_contains("path", "text")` | file exists and contains text |
| `file_missing_text("path", "text")` | file missing or doesn't contain text |
| `command("cmd")` | shell command exits 0 |
| `always` | never completes (recurring task) |

### Commit message conventions

- `Start Task: {name}` — task execution begins
- `Complete Task: {name}` — task finished, conditions passed
- `Incomplete Task: {name}` — task finished, conditions failed
- `Failed Task: {name}` — task crashed
- `New Task: {name}` — bootstrap wrote a new task
- Manual commits: short, imperative ("Add README.md", "Extract first task from bootstrap")

## Validation

```bash
bash -n factory.sh                                                  # shell syntax check
python3 -c "import ast; ast.parse(open('factory.sh').read())"       # won't work (it's bash with embedded python)
```

The embedded Python can be validated after extraction into the worktree:

```bash
python3 -c "import ast; ast.parse(open('.git-factory/worktree/factory.py').read())"
```

## Style

- **Bash**: `set -euo pipefail`, POSIX-safe, minimal external deps, color-coded stderr output (`\033[33m[factory:]\033[0m`)
- **Python**: standard library only, embedded in `factory.sh` via heredoc
- **Single-file distribution**: no config files, no `.env`, nothing to install
