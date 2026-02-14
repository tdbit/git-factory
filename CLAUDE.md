# git-factory

Autonomous software factory that embeds a Claude Code agent inside a git repo. A developer drops `factory.sh` into any repo, runs it once, and an AI agent bootstraps itself into a standalone `.factory/` directory where it continuously analyzes, plans, and improves the codebase.

## Quick reference

```bash
bash factory.sh              # first run: bootstrap + run
bash factory.sh [claude|codex]  # bootstrap with explicit provider
./factory                    # resume
bash factory.sh dev          # reset + bootstrap + run (no launcher)
bash factory.sh reset        # tear down only
./factory destroy            # remove everything, restore factory.sh
```

## Architecture

Everything lives in a single file: `factory.sh` (bash installer + embedded Python runner). No external dependencies beyond an agent CLI (`claude`, `claude-code`, or `codex`), `git`, `python3`, and `bash`.

- `factory.sh` creates `.factory/` as a standalone git repo (via `git init`)
- The embedded Python runner (`factory.py`) is extracted into `.factory/`
- Factory metadata (tasks, projects, initiatives) lives in the `.factory/` repo
- Project worktrees for source code changes are created under `.factory/worktrees/` as git worktrees of the source repo on `factory/*` branches
- `.factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files)
- After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

### Key paths (at runtime)

| Path | What |
|---|---|
| `factory.sh` | One-shot installer (replaced by `./factory` after first run) |
| `.factory/` | Standalone git repo for factory metadata |
| `.factory/factory.py` | Python orchestrator |
| `.factory/CLAUDE.md` | Agent's operating instructions (Purpose/Measures/Tests) |
| `.factory/agents/` | Agent persona definitions (markdown) |
| `.factory/initiatives/` | High-level goals (YYYY-slug.md) |
| `.factory/projects/` | Mid-level projects (YYYY-MM-slug.md) |
| `.factory/tasks/` | Task queue (markdown files with YAML frontmatter) |
| `.factory/config.json` | Bootstrap config (provider, default branch, worktrees path) |
| `.factory/state/` | Runtime state (pid file, last run log) |
| `.factory/logs/` | Agent run logs |
| `.factory/worktrees/` | Source repo worktrees for project tasks |

## Code layout

`factory.sh` is structured as:

1. **Constants** — `NOISES`, `ROOT`, `FACTORY_DIR`, `PROJECT_WORKTREES`, `PY_NAME`, `EXCLUDE_FILE`
2. **Provider detection** — first arg (`claude`/`codex`) or auto-detect from PATH
3. **Default branch detection** — from `origin/HEAD`, falling back to `main`/`master`/`HEAD`
4. **Dependency checks** — `PROVIDER` and `python3`
5. **Functions**:
   - `teardown()` — remove `.factory/`, worktrees, `factory/*` branches
   - `write_runner()` — embedded `factory.py` (~880 lines)
   - `write_claude_md()` — agent operating instructions template
   - `write_bootstrap_task()` — initial `define-purpose` task
   - `write_launcher()` — `./factory` launcher script
   - `write_hook()` — post-commit hook
   - `ensure_excluded()` — add `.factory/` to `.git/info/exclude`
   - `bootstrap()` — create dirs, write content, git init + commit
6. **Command dispatch** — `case` handles `reset`, `dev`, default (resume/bootstrap)

## Task system

Tasks are markdown files in `tasks/` named `YYYY-MM-DD-slug.md`. Each has YAML frontmatter (`tools`, `parent`) and markdown sections (`## Done`, `## Context`, `## Verify`).

### Completion conditions (in `## Done`)

| Condition | Passes when |
|---|---|
| `section_exists("text")` | text appears in `.factory/CLAUDE.md` |
| `no_section("text")` | text does not appear in `.factory/CLAUDE.md` |
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
```

The embedded Python can be validated after extraction:

```bash
python3 -c "import ast; ast.parse(open('.factory/factory.py').read())"
```

## Style

- **Bash**: `set -euo pipefail`, POSIX-safe, minimal external deps, color-coded stderr output (`\033[33m[factory:]\033[0m`)
- **Python**: standard library only, embedded in `factory.sh` via heredoc
- **Single-file distribution**: no config files, no `.env`, nothing to install
