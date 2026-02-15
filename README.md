# git-factory

I am not an expert in software development or AI, but I am lucky to be
surrounded by people who are.

After talking to a few of them (mostly founders & technical friends) about their
_Ralphs_ at dinner the other night, I thought I'd have a go at building one
myself. That's what you're looking at. I wrote it[^1] partly to understand, partly
out of curiosity and partly because I wanted to see what would happen if you
mashed software agents together with a bit more philosophy[^2].

The OG philosopher, Aristotle[^3], thought that if you want to understand
something, you have to understand four things about it: What it is made of, how
it is structured, where it came from, and _what it is for_. In software, the
first three are usually clear enough. The fourth one is often a bit woolly.

The Greeks had a word for this idea of what something is for, the idea of a
purpose: telos, meaning the end state. Teleology is the study of that end state.  So I wanted to see what would happen if we applied some teleology[^4] to software
agents. Proper telos. Something explicit. Something structured. Something they
could keep referring back to as they worked.

This repo, git-factory, is an attempt to see what happens.

`git-factory` is basically a loop that asks, why are we doing this? And then
keeps asking that question all the way down. Seriously, why are we doing this?
To what end?

**It's like the most vexatious co-worker you've ever had.**

That's it. That's all it does.

**Is it fast?**

_No._

**Is it safe?**

_No._

**Does it at least work?**

_Also no._

What it does, it does slowly, dangerously and unreliably. But (for me at
least) it's interesting to watch and see how and why it fails.

Like I said, this is an experiment.

**Use it at your own risk.**

Here's how:

```bash
curl -fsSLO https://raw.githubusercontent.com/tdbit/git-factory/main/factory.sh
bash factory.sh
```

N.B. You really should to check out [how it does that](#how-it-works) before you do.

What you'll get (what you should get) is a bunch of branches, prefixed with
`factory/`, that hopefully should have some bearing on improving your repo.  It
takes a while but you can check out what's going on.

Some of my design principles (see also Claude's longer [design decisions](#design-decisions)):
- **MAG-stack** (markdown, AI & git) for life
- **KISS AMIE** - keep it simple and make it easy
- One file to rule them all
- Quines are cool (this is not one so I'm calling it a QuAIne)
- Don't touch people's stuff

[^1]: For some loose definition of "write."
[^2]: By philosophy I mostly mean very old ideas about purpose, not anything especially clever.
[^3]: Socrates and Plato might dispute the branding.
[^4]: Teleology, not eschatology (the end times). But who knows 🤷 😬

---

Drop `factory.sh` into any git repo, run it, and an AI agent bootstraps itself into an isolated `.factory/` directory where it continuously analyzes, plans, and improves the codebase.

Supports **Claude Code** (`claude` / `claude-code`) and **Codex** (`codex`) — the first agent CLI found on `PATH` is used automatically.

## Quick start

```bash
# copy factory.sh into your repo and run it
cp /path/to/factory.sh .
bash factory.sh
```

First run bootstraps the agent, then prints:

```
factory: run ./factory to start
```

After that, just run `./factory` to resume.

## How it works

1. `factory.sh` creates `.factory/` as a standalone git repo (via `git init`) for factory metadata
2. It writes a Python runner (`factory.py`), markdown instruction files (`CLAUDE.md`, `INITIATIVES.md`, `PROJECTS.md`, `TASKS.md`, `PLANNING.md`, `EPILOGUE.md`), and a bootstrap task into `.factory/`
3. The runner launches the agent CLI in headless mode (Claude uses `--dangerously-skip-permissions`; Codex uses `exec --json`)
4. On first run, the agent reads your repo's `CLAUDE.md` and `README.md`, then writes Purpose, Measures, and Tests sections that guide all future work
5. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher
6. For project tasks that modify source code, the runner creates git worktrees under `.factory/worktrees/` on `factory/*` branches in the source repo

The factory is isolated — `.factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files). Project worktrees give the agent its own branches to work on without touching your working tree.

```
your-repo/
  factory.sh            # one-shot installer
  ./factory             # launcher (replaces factory.sh after bootstrap)
  .factory/             # standalone git repo, locally git-ignored
    factory.py          # python orchestrator
    CLAUDE.md           # agent's operating instructions
    INITIATIVES.md      # initiative format spec
    PROJECTS.md         # project format spec
    TASKS.md            # task format spec
    PLANNING.md         # planning agent instructions
    EPILOGUE.md         # project task epilogue template
    config.json         # bootstrap config (provider, default branch, worktrees path)
    agents/             # agent persona definitions (markdown)
    initiatives/        # high-level goals (YYYY-slug.md)
    projects/           # mid-level projects (YYYY-MM-slug.md)
    tasks/              # task queue (YYYY-MM-DD-slug.md)
    hooks/              # git hooks for the factory repo
    state/              # runtime state (pid, run logs)
    logs/               # agent run logs
    worktrees/          # source repo worktrees for project tasks
```

## The philoshophy part (per Claude: The Teleogical Architecture)

The core idea: an agent that knows *why* it's working makes better decisions than one that only knows *what* to do.

### Purpose framework (the final cause)

On first run, the agent reads your codebase and writes a three-level Purpose framework into `.factory/CLAUDE.md`:

| Level | Question | Scope |
|---|---|---|
| **Existential** | Why does this software exist? | The real-world outcome for users |
| **Strategic** | What improvements compound over time? | Medium-term direction and leverage |
| **Tactical** | What specific friction exists right now? | Near-term, observable, grounded in code |

Each level also gets **Measures** (how you know it's working) and **Tests** (questions to ask before committing). This is the agent's telos — it doesn't just have instructions, it has reasons.

### Planning hierarchy

Work is organized in three levels that map directly to the Purpose levels:

| Planning level | Purpose level | What it addresses |
|---|---|---|
| **Initiative** | Existential / Strategic | The big gaps between current state and purpose |
| **Project** | Strategic / Tactical | Scoped deliverables that compound |
| **Task** | Tactical | Specific, near-term changes |

Every initiative must trace to a Purpose bullet. Every project must advance an initiative. Every task must deliver a project artifact. The final cause propagates downward — a task that can't trace back to Purpose doesn't get created.

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

When no ready task exists, the runner automatically invokes a **planning agent** using the instructions in `.factory/PLANNING.md`. The planner:

1. Checks scarcity invariants
2. Promotes or creates initiatives / projects as needed
3. Creates exactly **one** new task per planning run
4. Commits the task file to the factory repo

The planning agent reads `INITIATIVES.md`, `PROJECTS.md`, and `TASKS.md` for format specs. Its instructions are editable after bootstrap — no need to re-extract the runner.

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
- **commit** — HEAD commit hash when the task completed

### Completion conditions

Listed in the `## Done` section, one per line. All must pass.

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


## TODO (these bits don't really work yet)

### Hooks

I was thinking it would be better if we had a pre-/post- commit hook that kicks of the planner but haven't fleshed that out.

### Agents

I thought we could have different agents for different tasks but really there's only one atm.  Right now (per Claude):

Agent definitions live in `agents/` as markdown files with optional YAML frontmatter. They define a system prompt and tool permissions that are prepended to the task prompt when referenced via the `agent:` frontmatter field.

```markdown
---
tools: Read,Write,Edit,Bash
---

You are a security-focused reviewer. Analyze code for vulnerabilities...
```

If no `agent:` field is set on a task, the default agent behavior is used.

### Dashboard

I thought it would cool to spin up a webserver and just pump the progress to that.  Keeping the file size managable meant I put that off.

### Management commands

I thought it would be cool if the `factory` command that got left behind could communicate with a background process managing the loop.

## Usage

### Run

```bash
./factory            # resumes where it left off
```

The agent works in the foreground, streaming tool calls and costs to the terminal.

### Dev mode

```bash
bash factory.sh dev          # tear down and re-bootstrap every time
bash factory.sh reset        # tear down only
```

### Destroy

```bash
./factory destroy
```

Removes `.factory/`, deletes `factory/*` project branches, restores the original `factory.sh`, and removes the `./factory` launcher. Prompts for confirmation.

## Configuration

All configuration is via environment variables — no config files.

| Variable | Default | Purpose |
|---|---|---|
| `FACTORY_CLAUDE_MODEL` | *(agent default)* | Override the Claude model |
| `FACTORY_CODEX_MODEL` | `gpt-5.2-codex` | Override the Codex model |
| `FACTORY_CODEX_MODEL_FALLBACKS` | `gpt-5-codex,o3` | Comma-separated fallback models for Codex |
| `FACTORY_HEARTBEAT_SEC` | `15` | Seconds between heartbeat messages during Codex runs |
| `FACTORY_TIMEOUT_SEC` | `0` (disabled) | Kill agent after N seconds |

## Requirements

- One of: [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, `claude-code`, or [`codex`](https://github.com/openai/codex) on `PATH`
- `git`
- `python3`
- `bash`

No other dependencies. Everything is self-contained in `factory.sh`.

## Design decisions

- **Standalone factory repo** — `.factory/` is its own git repo for metadata. Project worktrees give the agent isolated branches in the source repo. Your working tree and branch are never touched.
- **Multi-agent CLI support** — automatically detects and uses `claude`, `claude-code`, or `codex` (first found on `PATH`). Codex gets model fallback with retries.
- **No config files** — everything is self-contained in `factory.sh`. No `.env`, no `config.yaml`, no external dependencies beyond an agent CLI + git + python.
- **Self-replacing installer** — `factory.sh` is a one-shot installer that replaces itself with a tiny launcher script. The original is preserved in `.factory/` for `./factory destroy` to restore.
- **Headless agents** — Claude runs with `--dangerously-skip-permissions` in print mode; Codex runs with `exec --json`. No interactive prompts, no TUI.
- **Local-only git ignore** — uses `.git/info/exclude` instead of `.gitignore` so factory artifacts never pollute your repo's tracked files.
- **Autonomous planning** — when no tasks are ready, the runner reads `PLANNING.md` and invokes a planning agent that creates the next task following scarcity invariants.
- **Three-level work hierarchy** — initiatives, projects, and tasks provide structure without bureaucracy. Flat folders, frontmatter relationships, no nesting.
- **Agent personas** — custom agent definitions in `agents/` let tasks run with specialized system prompts and tool permissions.
- **Teleological grounding** — the Purpose framework gives the agent a final cause. Every piece of work traces back to *why*, not just *what*. This is the difference between an agent that produces commits and one that produces progress.
