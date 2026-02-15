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
purpose: telos, meaning the end state. Teleology is the study of that end state.
So I wanted to see what would happen if we applied some teleology[^4] to
software agents. Proper telos. Something explicit. Something structured.
Something they could keep referring back to as they worked.

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

`factory.sh` bootstraps an isolated `.factory/` git repo inside your project, writes a Python runner and markdown instruction files, then launches an AI agent in headless mode. The agent reads your codebase, defines a Purpose framework (why this software exists), and uses that to drive all future work. Source code changes happen on isolated `factory/*` branches via git worktrees — your working tree is never touched.

See **[DESIGN.md](DESIGN.md)** for the full design: bootstrap sequence, directory layout, purpose framework, work hierarchy, planning agent, and task system.

### The philoshophy part (per Claude: The Teleogical Architecture)

The core idea: an agent that knows *why* it's working makes better decisions
than one that only knows *what* to do.

Every piece of work traces back to a three-level Purpose framework (existential,
strategic, tactical) that the agent writes on first run from a bootstrap task.
Initiatives, projects, and tasks form a planning hierarchy where nothing gets
created unless it connects back to that purpose. See [DESIGN.md](DESIGN.md) for
the full breakdown.

## Usage

**Run**

```bash
./factory            # resumes where it left off
```

The agent works in the foreground, streaming tool calls and costs to the terminal.

**Dev mode**

```bash
bash factory.sh dev          # tear down and re-bootstrap every time
bash factory.sh reset        # tear down only
bash factory.sh help         # show help
```

**Teardown**

```bash
./factory teardown
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
- **Self-replacing installer** — `factory.sh` is a one-shot installer that replaces itself with a tiny launcher script. The original is preserved in `.factory/` for `./factory teardown` to restore.
- **Headless agents** — Claude runs with `--dangerously-skip-permissions` in print mode; Codex runs with `exec --json`. No interactive prompts, no TUI.
- **Local-only git ignore** — uses `.git/info/exclude` instead of `.gitignore` so factory artifacts never pollute your repo's tracked files.
- **Autonomous planning** — when no tasks are ready, the runner reads `PLANNING.md` and invokes a planning agent that creates the next task following scarcity invariants.
- **Failure handling** — when a task fails or completes with unmet conditions, the planning agent follows a structured failure analysis protocol (observe, diagnose, prescribe, retry) defined in `FAILURE.md`. Tasks track `stop_reason` and `status` in frontmatter so the agent can learn from what went wrong.
- **Three-level work hierarchy** — initiatives, projects, and tasks provide structure without bureaucracy. Flat folders, frontmatter relationships, no nesting.
- **Agent personas** — custom agent definitions in `agents/` let tasks run with specialized system prompts and tool permissions.
- **Teleological grounding** — the Purpose framework gives the agent a final cause. Every piece of work traces back to *why*, not just *what*. This is the difference between an agent that produces commits and one that produces progress.

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
