# Design

## Bootstrap sequence

1. `factory.sh` creates `.factory/` as a standalone git repo (via `git init`) for factory metadata
2. It clones the source repo into `.factory/clone/` and adds a `factory` remote on the source repo pointing at the clone
3. It writes Python files (`library.py` + `factory.py`), markdown instruction files (`PROLOGUE.md`, `EPILOGUE.md`, `specs/AGENTS.md`, `specs/INITIATIVES.md`, `specs/PROJECTS.md`, `specs/TASKS.md`, `agents/THINKER.md`, `agents/PLANNER.md`, `agents/TASKER.md`, `agents/FIXER.md`, `agents/DEVELOPER.md`) into `.factory/`
4. The runner launches the agent CLI in headless mode (Claude uses `--dangerously-skip-permissions -p --output-format stream-json`; Codex uses `exec --json`)
5. On first run, the runner auto-creates a planner task; the planner sees no understanding and creates a thinker task; the thinker examines the repo and feeds context back to the planner, which then creates initiatives, projects, and tasks
6. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher
7. For project tasks that modify source code, the runner creates git worktrees under `.factory/worktrees/` from the clone on `factory/*` branches

The factory is isolated — `.factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files). The clone and its worktrees give the agent its own branches to work on without touching your working tree.

## Directory layout

```
your-repo/
  factory.sh            # one-shot installer
  ./factory             # launcher (replaces factory.sh after bootstrap)
  .factory/             # standalone git repo, locally git-ignored
    library.py          # shared python helpers (parsing, conditions, queue)
    factory.py          # python orchestrator (runner loop, agent invocation)
    factory.sh          # preserved copy of original installer (for teardown restore)
    PROLOGUE.md         # prologue prepended to all task prompts
    EPILOGUE.md         # project task epilogue template
    config.json         # bootstrap config (provider, default branch, worktrees path)
    .gitignore          # ignores state/, logs/, worktrees/, clone/
    clone/              # clone of source repo (base for project branches)
    specs/              # format specs (markdown)
      AGENTS.md         # agent format spec
      INITIATIVES.md    # initiative format spec
      PROJECTS.md       # project format spec
      TASKS.md          # task format spec
    agents/             # agent persona definitions (markdown)
      THINKER.md        # thinking/understanding agent
      PLANNER.md        # planning agent instructions
      TASKER.md         # task decomposition agent
      FIXER.md          # failure analysis protocol
      DEVELOPER.md      # source code development agent
    initiatives/        # high-level goals (NNNN-slug.md)
    projects/           # mid-level projects (NNNN-slug.md)
    tasks/              # task queue (NNNN-slug.md)
    hooks/              # git hooks for the factory repo
      post-commit       # post-commit hook
    state/              # runtime state (pid file, last run log)
    logs/               # agent run logs
    worktrees/          # clone worktrees for project tasks
```

## Purpose framework (the final cause)

On first run, the thinker agent examines the source repo and writes `PURPOSE.md` in the factory root. This is the factory's telos — it doesn't just have instructions, it has reasons.

The purpose file has four sections:

| Section | What it answers | Who uses it |
|---|---|---|
| **Purpose** | Why does this entity exist? What becomes true when it succeeds? | Everyone — orients all work |
| **Measures** | How do you observe purpose being fulfilled better or worse? | Planner (find gaps), Fixer (diagnose failures) |
| **Parts** | What are the essential logical constituents? | Planner (scope work to subsystems) |
| **Principles** | What cross-cutting conventions and constraints apply? | Developer (make consistent decisions) |

Measures must track **degree** (not pass/fail) and include a **method of observation** — a command, metric, or concrete thing you can point at. Parts are only the essential ones (traces to purpose, not to platform/toolchain). Principles span the whole entity; if it only applies to one part, it belongs to that part.

## Planning hierarchy

Work is organized in three levels, each tracing back to `PURPOSE.md`:

| Level | What it addresses | Traces to |
|---|---|---|
| **Initiative** | The biggest gap between current state and purpose | A measure from `PURPOSE.md` |
| **Project** | Scoped deliverables that close part of an initiative | An initiative |
| **Task** | Atomic unit of agent work | A project |

Every initiative opens by restating the purpose and naming the measure it advances. Every project must advance an initiative. Every task must deliver a project artifact. The final cause propagates downward — a task that can't trace back to Purpose doesn't get created.

## Work hierarchy

All work is organized in three flat folders with relationships defined by frontmatter fields — no directory nesting.

| Level | Folder | Naming | Purpose |
|---|---|---|---|
| Initiative | `initiatives/` | `NNNN-slug.md` | High-level goals |
| Project | `projects/` | `NNNN-slug.md` | Mid-level workstreams |
| Task | `tasks/` | `NNNN-slug.md` | Atomic units of agent work |

**Structural relationships**

- `parent:` links a task → project, or a project → initiative
- `previous:` defines sequential dependency between tasks
- No `parent` means the task is a **factory maintenance task**

**Lifecycle states**

All initiatives, projects, and tasks share the same lifecycle:

| State | Meaning |
|---|---|
| `backlog` | Defined but not active |
| `active` | Currently in play |
| `suspended` | Intentionally paused |
| `completed` | Finished successfully |
| `stopped` | Ended and will not resume |

There is no `failed` state. Failure is represented as `status: stopped` with `stop_reason: failed`.

**Scarcity invariants**

The system enforces focus by maintaining:

- Exactly **1 active initiative**
- At most **2 active projects**
- At most **3 active tasks**
- At most **1 active unparented (factory) task**

## Planning agent

When no ready task exists, the runner invokes agents in sequence to fill the queue:

1. **Thinker** (`agents/THINKER.md`) — if no `PURPOSE.md` exists, examines the source repo and writes one (purpose, measures, parts, principles)
2. **Planner** (`agents/PLANNER.md`) — reads `PURPOSE.md`, manages initiatives and projects, activates 1–2 projects. Does **not** create tasks.
3. **Tasker** (`agents/TASKER.md`) — decomposes active projects into tasks, creating exactly one task per run

The planner reads `specs/INITIATIVES.md` and `specs/PROJECTS.md` for format specs. The tasker reads `specs/TASKS.md`. All agent instructions are editable after bootstrap — no need to re-extract the runner.

## Failure handling and self-modification

When a task fails or completes with unmet conditions, the runner marks it `status: stopped` with a `stop_reason` (`failed` or `incomplete`). The runner then invokes a failure review agent using the protocol in `.factory/agents/FIXER.md`, passing the task content, condition results, and last 50 lines of the run log as context.

The protocol has four steps:

1. **Observe** — read the task file, run log, and git diff to understand what actually happened
2. **Diagnose** — identify which contract (from specs or agent definitions) was violated and what check should have caught it
3. **Prescribe** — create a new task that targets a *factory system file* (`library.py`, `factory.py`, `PROLOGUE.md`, `agents/*.md`, etc.) to close the gap
4. **Retry** — only after the systemic fix is in place, create a new task for the original work

This is the self-modifying part: the factory doesn't just retry failed work — it modifies its own instructions, runner code, or format specs to prevent the same class of failure from recurring. The failed task stays stopped. The fix task strengthens a measure or adds a missing check. The retry task benefits from the improved system.

Failures are classified by level:

| Level | Scope | Example |
|---|---|---|
| **Existential** | Factory cannot operate | Runner crashes, bootstrap fails |
| **Strategic** | Systematically wrong results | Prompt drops context, specs are ambiguous |
| **Tactical** | Narrow, one-off gap | Missing instruction, edge case in a condition |

The level determines the scope of the prescription — existential failures demand runner fixes, strategic failures demand instruction rewrites, tactical failures demand narrower patches.

## Task system

Tasks are markdown files in `tasks/` named `NNNN-slug.md` (monotonic counter, e.g. `0001-slug.md`). Each task has minimal YAML frontmatter for runner metadata, then a fixed set of markdown sections:

```markdown
---
tools: Read,Write,Edit,Bash
author: planner
parent: projects/name.md
previous: YYYY-MM-DD-other-task.md
handler: agents/my-agent.md
---

The prompt — what the agent should do. Be specific and concrete.

## Done

Completion conditions checked by the runner after the agent finishes.
One per line, all must pass.

- `file_contains("PURPOSE.md", "# Purpose")`
- `file_exists("src/config.py")`

## Context

Why this task exists and what purpose it serves.

## Verify

How the agent should check its own work before committing.
```

**Frontmatter fields**

Author-set:

- **tools** — which agent tools are allowed (default: `Read,Write,Edit,Bash,Glob,Grep`)
- **author** — who created this task (e.g. `planner`, `fixer`, `factory`)
- **parent** — project file this task advances (e.g. `projects/2026-auth-hardening.md`)
- **previous** — another task file that must complete first (dependency chain)
- **handler** — agent persona to use (e.g. `agents/my-agent.md`); see [Agents](#agents)

Runner-managed (set automatically):

- **status** — lifecycle state: `backlog`, `active`, `suspended`, `completed`, `stopped`
- **stop_reason** — required when `status: stopped` (e.g. `failed`)
- **pid** — process ID of the runner
- **session** — agent session ID
- **commit** — HEAD commit hash when the task completed

**Completion conditions**

Listed in the `## Done` section, one per line. All must pass.

| Condition | Passes when |
|---|---|
| `file_exists("path")` | file exists in the worktree (supports date glob patterns) |
| `file_absent("path")` | file does not exist |
| `file_contains("path", "text")` | file exists and contains text |
| `file_missing_text("path", "text")` | file missing or doesn't contain text |
| `command("cmd")` | shell command exits 0 |
| `never` | never completes (recurring task) |
