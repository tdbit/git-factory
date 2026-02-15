# Design

## Bootstrap sequence

1. `factory.sh` creates `.factory/` as a standalone git repo (via `git init`) for factory metadata
2. It writes a Python runner (`factory.py`), markdown instruction files (`CLAUDE.md`, `INITIATIVES.md`, `PROJECTS.md`, `TASKS.md`, `PLANNING.md`, `EPILOGUE.md`), and a bootstrap task into `.factory/`
3. The runner launches the agent CLI in headless mode (Claude uses `--dangerously-skip-permissions`; Codex uses `exec --json`)
4. On first run, the agent reads your repo's `CLAUDE.md` and `README.md`, then writes Purpose, Measures, and Tests sections that guide all future work
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

**Frontmatter fields**

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

**Completion conditions**

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
