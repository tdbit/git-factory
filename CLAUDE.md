# git-factory

Autonomous software factory that embeds a Claude Code agent inside a git repo. A developer drops `factory.sh` into any repo, runs it once, and an AI agent bootstraps itself into a standalone `.factory/` directory where it continuously analyzes, plans, and improves the codebase.

## Quick reference

```bash
bash factory.sh              # first run: bootstrap + launch
bash factory.sh [claude|codex]  # bootstrap with explicit provider
./factory                    # resume where it left off
bash factory.sh bootstrap    # bootstrap only (no launch)
bash factory.sh explain      # use the agent to explain factory.sh
bash factory.sh dump         # write all factory files to ./factory_dump/
bash factory.sh teardown     # tear down only (with confirmation)
bash factory.sh help         # show help
./factory teardown           # restore factory.sh, then tear down
```

## Architecture

Everything lives in a single file: `factory.sh` (bash installer + embedded Python). No external dependencies beyond an agent CLI (`claude`, `claude-code`, or `codex`), `git`, `python3`, and `bash`.

- `factory.sh` creates `.factory/` as a standalone git repo (via `git init`) for factory metadata
- The source repo is cloned into `.factory/clone/` — all project branches and worktrees are created from this clone
- A `factory` remote is added to the source repo pointing at the clone
- The embedded Python (`library.py` + `factory.py`) is extracted into `.factory/`
- Factory metadata (tasks, projects, initiatives) lives in the `.factory/` repo
- Project worktrees for source code changes are created under `.factory/worktrees/` as git worktrees of the clone on `factory/*` branches
- `.factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files)
- After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

### Key paths (at runtime)

| Path | What |
|---|---|
| `factory.sh` | One-shot installer (replaced by `./factory` after first run) |
| `.factory/` | Standalone git repo for factory metadata |
| `.factory/library.py` | Shared Python helpers (task parsing, conditions, queue) |
| `.factory/factory.py` | Python orchestrator (runner loop, agent invocation) |
| `.factory/clone/` | Clone of the source repo (base for project branches/worktrees) |
| `.factory/PROLOGUE.md` | Prologue prepended to all task prompts |
| `.factory/EPILOGUE.md` | Project task epilogue template |
| `.factory/specs/AGENTS.md` | Agent format spec |
| `.factory/specs/INITIATIVES.md` | Initiative format spec |
| `.factory/specs/PROJECTS.md` | Project format spec |
| `.factory/specs/TASKS.md` | Task format spec |
| `.factory/agents/` | Agent definitions (markdown) |
| `.factory/agents/THINKER.md` | Thinking/understanding agent instructions |
| `.factory/agents/PLANNER.md` | Planning agent instructions |
| `.factory/agents/TASKER.md` | Task decomposition agent instructions |
| `.factory/agents/FIXER.md` | Failure analysis protocol |
| `.factory/agents/DEVELOPER.md` | Source code development agent instructions |
| `.factory/initiatives/` | High-level goals (NNNN-slug.md) |
| `.factory/projects/` | Mid-level projects (NNNN-slug.md) |
| `.factory/tasks/` | Task queue (NNNN-slug.md, YAML frontmatter) |
| `.factory/config.json` | Bootstrap config (provider, default branch, worktrees path) |
| `.factory/state/` | Runtime state (pid file, last run log) |
| `.factory/logs/` | Agent run logs |
| `.factory/worktrees/` | Source repo worktrees for project tasks |

## Code layout

`factory.sh` is structured as:

1. **Constants** — `SOURCE_DIR`, `FACTORY_DIR`, `CLONE_DIR`, `PROJECT_WORKTREES`, `PY_NAME`, `EXCLUDE_FILE`
2. **Provider detection** — first arg (`claude`/`codex`) or auto-detect from PATH; also `--keep-script` option
3. **Default branch detection** — from `origin/HEAD`, falling back to `main`/`master`/`HEAD`
4. **Dependency checks** — `PROVIDER` and `python3`
5. **Functions**:
   - `write_python()` — embedded `library.py` (~270 lines) + `factory.py` (~570 lines)
   - `write_prologue_md()` — prologue prepended to all task prompts
   - `write_specs()` — all four spec files (AGENTS, INITIATIVES, PROJECTS, TASKS) into `specs/`
   - `write_agents()` — all five agent files (THINKER, PLANNER, TASKER, FIXER, DEVELOPER) into `agents/`
   - `write_epilogue_md()` — project task epilogue template
   - `write_launcher()` — `./factory` launcher script
   - `write_hook()` — post-commit hook (written to `hooks/`)
   - `setup_excludes()` — add `.factory/` and `/factory` to `.git/info/exclude`
   - `remove_script()` — delete `factory.sh` after bootstrap
   - `write_files()` — write all factory files to a given directory
   - `setup_repo()` — git init `.factory/`, set hooks path, initial commit
   - `teardown()` — remove `factory` remote, `rm -rf .factory/`, remove launcher
   - `bootstrap()` — orchestrates setup: excludes → files → clone → remote → repo → launcher → remove script
6. **Command dispatch** — `case` handles `help`, `bootstrap`, `teardown`, `explain`, `dump`, default (resume/bootstrap+launch)

## Task system

Tasks are markdown files in `tasks/` named `NNNN-slug.md` (monotonic counter, e.g. `0001-slug.md`). Projects and initiatives use the same scheme, each with independent counters. Each has YAML frontmatter (`tools`, `author`, `parent`, `previous`, `handler`) and runner-managed fields (`status`, `stop_reason`, `pid`, `session`, `commit`). Body contains markdown sections (`## Done`, `## Context`, `## Verify`).

### Completion conditions (in `## Done`)

| Condition | Passes when |
|---|---|
| `file_exists("path")` | file exists in the worktree |
| `file_absent("path")` | file does not exist |
| `file_contains("path", "text")` | file exists and contains text |
| `file_missing_text("path", "text")` | file missing or doesn't contain text |
| `command("cmd")` | shell command exits 0 |
| `never` | never completes (recurring task) |

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
```

The embedded Python can be validated after extraction:

```bash
python3 -c "import ast; ast.parse(open('.factory/factory.py').read())"
```

## Style

- **Bash**: `set -euo pipefail`, POSIX-safe, minimal external deps, color-coded stderr output (`\033[33m[factory:]\033[0m`)
- **Python**: standard library only, embedded in `factory.sh` via heredoc
- **Single-file distribution**: no config files, no `.env`, nothing to install
