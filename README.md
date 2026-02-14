# git-factory

An autonomous software factory powered by AI coding agents. Drop `factory.sh` into any git repo, run it, and an agent bootstraps itself into an isolated worktree where it analyzes, plans, and improves your codebase continuously.

Supports **Claude Code** (`claude` / `claude-code`) and **Codex** (`codex`) — the first agent CLI found on `PATH` is used automatically.

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

1. `factory.sh` creates a `factory/{repo}` branch and a git worktree at `.git-factory/worktree/`
2. It writes a Python runner (`factory.py`) and a `CLAUDE.md` into the worktree
3. The runner launches the agent CLI in headless mode (Claude uses `--dangerously-skip-permissions`; Codex uses `exec --json`)
4. On first run, the agent reads your repo's `CLAUDE.md` and `README.md`, then writes Purpose, Measures, and Tests sections that guide all future work
5. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

The factory branch is isolated — the agent can read your source repo but only writes to its own worktree. Your working tree stays clean.

```
your-repo/
  factory.sh            # one-shot installer
  ./factory             # launcher (replaces factory.sh after bootstrap)
  .git-factory/         # created at runtime, locally git-ignored
    worktree/           # git worktree on the factory/{repo} branch
      CLAUDE.md         # agent's operating instructions
      factory.py        # python orchestrator
      agents/           # agent persona definitions (markdown)
      initiatives/      # high-level goals (YYYY-slug.md)
      projects/         # mid-level projects (YYYY-MM-slug.md)
      tasks/            # task queue (YYYY-MM-DD-slug.md)
      hooks/            # git hooks for the worktree
      state/            # runtime state (pid, cli path, init timestamp)
```

## Work hierarchy

All work is organized in three flat folders with relationships defined by frontmatter fields — no directory nesting.

| Level | Folder | Naming | Purpose |
|---|---|---|---|
| Initiative | `initiatives/` | `YYYY-slug.md` | High-level goals |
| Project | `projects/` | `YYYY-MM-slug.md` | Mid-level workstreams |
| Task | `tasks/` | `YYYY-MM-DD-slug.md` | Atomic units of agent work |

### Structural relationships

- `parent:` links a task → project, or a project → initiative
- `previous:` defines sequential dependency between tasks
- No `parent` means the task is a **factory maintenance task**

### Lifecycle states

All initiatives, projects, and tasks share the same lifecycle:

| State | Meaning |
|---|---|
| `backlog` | Defined but not active |
| `active` | Currently in play |
| `suspended` | Intentionally paused |
| `completed` | Finished successfully |
| `stopped` | Ended and will not resume |

There is no `failed` state. Failure is represented as `status: stopped` with `stop_reason: failed`.

### Scarcity invariants

The system enforces focus by maintaining:

- Exactly **1 active initiative**
- At most **2 active projects**
- At most **3 active tasks**
- At most **1 active unparented (factory) task**

## Planning agent

When no ready task exists, the runner automatically invokes a built-in **planning agent** that:

1. Checks scarcity invariants
2. Promotes or creates initiatives / projects as needed
3. Creates exactly **one** new task per planning run
4. Commits the task file to the worktree

The planning agent follows strict rules: prefer refinement over creation, never create parallel structure, and produce tasks that are atomic and completable in a single agent session.

## Task system

Tasks are markdown files in `tasks/` named `YYYY-MM-DD-slug.md`. Each task has minimal YAML frontmatter for runner metadata, then a fixed set of markdown sections:

```markdown
---
tools: Read,Write,Edit,Bash
parent: projects/name.md
previous: YYYY-MM-DD-other-task.md
agent: agents/my-agent.md
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

- **tools** — which agent tools are allowed (default: `Read,Write,Edit,Bash,Glob,Grep`)
- **parent** — project file this task advances (e.g. `projects/2026-auth-hardening.md`)
- **previous** — another task file that must complete first (dependency chain)
- **agent** — agent persona to use (e.g. `agents/my-agent.md`); see [Agents](#agents)

Runner-managed (set automatically):

- **status** — lifecycle state: `backlog`, `active`, `suspended`, `completed`, `stopped`
- **stop_reason** — required when `status: stopped` (e.g. `failed`)
- **pid** — process ID of the runner
- **session** — agent session ID
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
| `always` | never completes (recurring task) |

## Agents

Agent definitions live in `agents/` as markdown files with optional YAML frontmatter. They define a system prompt and tool permissions that are prepended to the task prompt when referenced via the `agent:` frontmatter field.

```markdown
---
tools: Read,Write,Edit,Bash
---

You are a security-focused reviewer. Analyze code for vulnerabilities...
```

If no `agent:` field is set on a task, the default agent behavior is used.

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

Removes `.git-factory/`, deletes the `factory/{repo}` branch, restores the original `factory.sh`, and removes the `./factory` launcher. Prompts for confirmation.

## Configuration

All configuration is via environment variables — no config files.

| Variable | Default | Purpose |
|---|---|---|
| `FACTORY_CLAUDE_MODEL` | *(agent default)* | Override the Claude model |
| `FACTORY_CODEX_MODEL` | `gpt-5.2-codex` | Override the Codex model |
| `FACTORY_CODEX_MODEL_FALLBACKS` | `gpt-5-codex,o3` | Comma-separated fallback models for Codex |
| `FACTORY_HEARTBEAT_SEC` | `15` | Seconds between heartbeat messages during Codex runs |
| `FACTORY_BRANCH` | `factory/{repo}` | Override the factory branch name |

## Requirements

- One of: [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `claude-code`, or [`codex`](https://github.com/openai/codex) on `PATH`
- `git`
- `python3`
- `bash`

No other dependencies. Everything is self-contained in `factory.sh`.

## How the agent operates

The agent's behavior is defined by the `CLAUDE.md` in the worktree. After bootstrap, this file contains:

- **Purpose** — what "better" means for your codebase, at existential, strategic, and tactical levels
- **Measures** — observable signals of progress, each with a way to check it
- **Tests** — gate questions the agent asks before every change

The agent reads your source repo's `CLAUDE.md` and `README.md` to understand what it's working with, then writes these sections based on what it finds.

## Design decisions

- **Git worktree isolation** — the agent works on its own branch in its own directory. Your working tree and branch are never touched.
- **Multi-agent CLI support** — automatically detects and uses `codex`, `claude`, or `claude-code` (first found on `PATH`). Codex gets model fallback with retries.
- **No config files** — everything is self-contained in `factory.sh`. No `.env`, no `config.yaml`, no external dependencies beyond an agent CLI + git + python.
- **Self-replacing installer** — `factory.sh` is a one-shot installer that replaces itself with a tiny launcher script. The original is preserved in the worktree for `./factory destroy` to restore.
- **Headless agents** — Claude runs with `--dangerously-skip-permissions` in print mode; Codex runs with `exec --json`. No interactive prompts, no TUI.
- **Local-only git ignore** — uses `.git/info/exclude` instead of `.gitignore` so factory artifacts never pollute your repo's tracked files.
- **Autonomous planning** — when no tasks are ready, a built-in planning agent creates the next task following scarcity invariants, ensuring the factory always has work.
- **Three-level work hierarchy** — initiatives, projects, and tasks provide structure without bureaucracy. Flat folders, frontmatter relationships, no nesting.
- **Agent personas** — custom agent definitions in `agents/` let tasks run with specialized system prompts and tool permissions.
