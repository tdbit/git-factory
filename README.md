# factory

An autonomous software factory powered by Claude Code. Drop `factory.sh` into any git repo, run it, and an AI agent bootstraps itself into an isolated worktree where it analyzes, plans, and improves your codebase continuously.

## Quick start

```bash
# copy factory.sh into your repo and run it
cp /path/to/factory.sh .
bash factory.sh
```

First run bootstraps the agent, then prints:

```
factory: worktree at .git-factory/worktree
factory: run ./factory to start
```

After that, just run `./factory` to resume.

## How it works

1. `factory.sh` creates a `factory` branch and a git worktree at `.git-factory/worktree/`
2. It writes a Python runner (`factory.py`) and a `CLAUDE.md` into the worktree
3. The runner launches Claude Code in headless mode with `--dangerously-skip-permissions`
4. On first run, the agent reads your repo's `CLAUDE.md` and `README.md`, then writes Purpose, Measures, and Tests sections that guide all future work
5. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

The factory branch is isolated — the agent can read your source repo but only writes to its own worktree. Your working tree stays clean.

```
your-repo/
  factory.sh            # one-shot installer
  ./factory             # launcher (replaces factory.sh after bootstrap)
  .git-factory/         # created at runtime, locally git-ignored
    worktree/           # git worktree on the `factory` branch
      CLAUDE.md         # agent's operating instructions
      factory.py        # python orchestrator
      tasks/            # task queue (markdown files with YAML frontmatter)
      hooks/            # git hooks for the worktree
      state/            # runtime state (pid, claude path, init timestamp)
```

## Task system

Tasks are markdown files in `tasks/` named `YYYY-MM-DD-slug.md`. Each task has minimal YAML frontmatter for runner metadata, then a fixed set of markdown sections:

```markdown
---
tools: Read,Write,Edit,Bash
parent: YYYY-MM-DD-other-task.md
---

The prompt — what the agent should do. Be specific and concrete.

## Done

Completion conditions checked by the runner after the agent finishes.
One per line, all must pass.

- `section_exists("## Purpose")`
- `file_exists("src/config.py")`

## Context

Why this task exists and what purpose it serves.

## Verify

How the agent should check its own work before committing.
```

### Frontmatter fields

Author-set:

- **tools** — which Claude Code tools the agent can use (default: `Read,Write,Edit,Bash,Glob,Grep`)
- **parent** — another task file that must complete first (dependency chain)

Runner-managed (set automatically):

- **status** — lifecycle state: `active`, `completed`, `failed`, `incomplete`
- **pid** — process ID of the runner
- **session** — Claude session ID
- **branch** — git branch the task ran on
- **commit** — HEAD commit hash when the task completed

### Completion conditions

Listed in the `## Done` section, one per line. All must pass.

| Condition | Passes when |
|---|---|
| `section_exists("text")` | text appears in `CLAUDE.md` |
| `no_section("text")` | text does not appear in `CLAUDE.md` |
| `file_exists("path")` | file exists in the worktree |
| `file_absent("path")` | file does not exist |
| `file_contains("path", "text")` | file exists and contains text |
| `file_missing_text("path", "text")` | file missing or doesn't contain text |
| `command("cmd")` | shell command exits 0 |

### Runtime state

The runner writes `status`, `pid`, `session`, and `branch` into the YAML frontmatter as it executes. These fields are managed by the runner — never write them manually.

## Usage

### Run

```bash
./factory            # resumes where it left off
```

The agent works in the foreground, streaming tool calls and costs to the terminal.

### Dev mode

```bash
bash factory.sh dev          # tear down and re-bootstrap every time
bash factory.sh dev reset    # tear down only, don't run
```

### Destroy

```bash
./factory destroy
```

Removes `.git-factory/`, deletes the `factory` branch, restores the original `factory.sh`, and removes the `./factory` launcher. Prompts for confirmation.

## Requirements

- [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `claude-code`, or `codex` on `PATH`
- `git`
- `python3`
- `bash`

No other dependencies. Everything is self-contained in `factory.sh`.

## How the agent operates

The agent's behavior is defined by the `CLAUDE.md` in the worktree. After bootstrap, this file contains:

- **Purpose** — what "better" means for your codebase, at existential, strategic, and operational levels
- **Measures** — observable signals of progress, each with a way to check it
- **Tests** — gate questions the agent asks before every change

The agent reads your source repo's `CLAUDE.md` and `README.md` to understand what it's working with, then writes these sections based on what it finds.

## Design decisions

- **Git worktree isolation** — the agent works on its own branch in its own directory. Your working tree and branch are never touched.
- **No config files** — everything is self-contained in `factory.sh`. No `.env`, no `config.yaml`, no external dependencies beyond claude + git + python.
- **Self-replacing installer** — `factory.sh` is a one-shot installer that replaces itself with a tiny launcher script. The original is preserved in the worktree for `./factory destroy` to restore.
- **Headless Claude** — runs with `--dangerously-skip-permissions` in print mode. No interactive prompts, no TUI. Tool calls are streamed as JSON and logged to the terminal.
- **Local-only git ignore** — uses `.git/info/exclude` instead of `.gitignore` so factory artifacts never pollute your repo's tracked files.
- **Task-based execution** — work is broken into markdown task files with explicit tool permissions, completion conditions, and dependency ordering.
