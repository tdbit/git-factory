# Design

## Bootstrap sequence

1. `factory.sh` creates `.factory/` as a standalone git repo (via `git init`) for factory metadata
2. It writes a Python runner (`factory.py`), markdown instruction files (`CLAUDE.md`, `INITIATIVES.md`, `PROJECTS.md`, `TASKS.md`, `EPILOGUE.md`, `agents/PLANNER.md`, `agents/FIXER.md`), and two chained bootstrap tasks into `.factory/`
3. The runner launches the agent CLI in headless mode (Claude uses `--dangerously-skip-permissions -p --output-format stream-json`; Codex uses `exec --json`)
4. On first run, the agent executes two chained bootstrap tasks: first it defines the factory's own Purpose, then it reads your repo and defines the repo's Purpose, Measures, and Tests
5. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher
6. For project tasks that modify source code, the runner creates git worktrees under `.factory/worktrees/` on `factory/*` branches in the source repo

The factory is isolated — `.factory/` is locally ignored via `.git/info/exclude` (never pollutes tracked files). Project worktrees give the agent its own branches to work on without touching your working tree.

## Directory layout

```
your-repo/
  factory.sh            # one-shot installer
  ./factory             # launcher (replaces factory.sh after bootstrap)
  .factory/             # standalone git repo, locally git-ignored
    factory.py          # python orchestrator
    factory.sh          # preserved copy of original installer (for teardown restore)
    CLAUDE.md           # agent's operating instructions
    INITIATIVES.md      # initiative format spec
    PROJECTS.md         # project format spec
    TASKS.md            # task format spec
    EPILOGUE.md         # project task epilogue template
    PURPOSE.md          # purpose, measures, and tests (created by bootstrap task)
    config.json         # bootstrap config (provider, default branch, worktrees path)
    .gitignore          # ignores state/, logs/, worktrees/
    agents/             # agent persona definitions (markdown)
      PLANNER.md        # planning agent instructions
      FIXER.md          # failure analysis protocol
    initiatives/        # high-level goals (YYYY-slug.md)
    projects/           # mid-level projects (YYYY-MM-slug.md)
    tasks/              # task queue (YYYY-MM-DD-slug.md)
    hooks/              # git hooks for the factory repo
      post-commit       # post-commit hook
    state/              # runtime state (pid file, last run log)
    logs/               # agent run logs
    worktrees/          # source repo worktrees for project tasks
```

## Purpose framework (the final cause)

On first run, the agent reads your codebase and writes a three-level Purpose framework into `.factory/CLAUDE.md`:

| Level | Question | Scope |
|---|---|---|
| **Existential** | Why does this software exist? | The real-world outcome for users |
| **Strategic** | What improvements compound over time? | Medium-term direction and leverage |
| **Tactical** | What specific friction exists right now? | Near-term, observable, grounded in code |

Each level also gets **Measures** (how you know it's working) and **Tests** (questions to ask before committing). This is the agent's telos — it doesn't just have instructions, it has reasons.

## Planning hierarchy

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

When no ready task exists, the runner automatically invokes a **planning agent** using the instructions in `.factory/agents/PLANNER.md`. The planner:

1. Checks scarcity invariants
2. Promotes or creates initiatives / projects as needed
3. Creates exactly **one** new task per planning run
4. Commits the task file to the factory repo

The planning agent reads `INITIATIVES.md`, `PROJECTS.md`, and `TASKS.md` for format specs. Its instructions in `agents/PLANNER.md` are editable after bootstrap — no need to re-extract the runner.

## Failure handling and self-modification

When a task fails or completes with unmet conditions, the runner marks it `status: stopped` with a `stop_reason` (`failed` or `incomplete`). The runner then invokes a failure review agent using the protocol in `.factory/agents/FIXER.md`, passing the task content, condition results, and last 50 lines of the run log as context.

The protocol has four steps:

1. **Observe** — read the task file, run log, and git diff to understand what actually happened
2. **Diagnose** — identify which factory Measure (from `PURPOSE.md`) was violated and which Test should have caught it
3. **Prescribe** — create a new task that targets a *factory system file* (`factory.py`, `CLAUDE.md`, `agents/PLANNER.md`, etc.) to close the gap
4. **Retry** — only after the systemic fix is in place, create a new task for the original work

This is the self-modifying part: the factory doesn't just retry failed work — it modifies its own instructions, runner code, or format specs to prevent the same class of failure from recurring. The failed task stays stopped. The fix task strengthens a Measure or adds a Test. The retry task benefits from the improved system.

Failures are classified by level:

| Level | Scope | Example |
|---|---|---|
| **Existential** | Factory cannot operate | Runner crashes, bootstrap fails |
| **Strategic** | Systematically wrong results | Prompt drops context, specs are ambiguous |
| **Tactical** | Narrow, one-off gap | Missing instruction, edge case in a condition |

The level determines the scope of the prescription — existential failures demand runner fixes, strategic failures demand instruction rewrites, tactical failures demand narrower patches.

## Task system

Tasks are markdown files in `tasks/` named `YYYY-MM-DD-slug.md`. Each task has minimal YAML frontmatter for runner metadata, then a fixed set of markdown sections:

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
