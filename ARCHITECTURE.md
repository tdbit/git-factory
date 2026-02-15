# How it works

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
