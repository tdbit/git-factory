# factory

An autonomous software factory powered by Claude Code. Drop `factory.sh` into any git repo, run it, and an AI agent bootstraps itself into a persistent worktree where it can analyze, plan, and improve your codebase continuously.

## How it works

```
your-repo/
  factory.sh          # the installer — run this once
  .git-factory/       # created at runtime (git-ignored)
    worktree/         # git worktree on the `factory` branch
      CLAUDE.md       # agent's operating instructions
      .git-factory/
        factory.py    # python runner that orchestrates claude
        state/        # initialization state
```

1. `factory.sh` creates a `factory` branch and a git worktree at `.git-factory/worktree/`
2. It writes a Python runner (`factory.py`) and a `CLAUDE.md` with bootstrap instructions into the worktree
3. The runner launches Claude Code in headless mode (`--dangerously-skip-permissions`)
4. On first run, the agent reads your repo's `CLAUDE.md` and `README.md`, then writes Purpose, Measures, and Tests sections that guide all future work
5. After bootstrap, `factory.sh` replaces itself with a minimal `./factory` launcher

The factory branch is isolated — the agent can read your source repo but only writes to its own worktree. Your working tree stays clean.

## Usage

### Install

```bash
# copy factory.sh into your repo
cp /path/to/factory.sh .
bash factory.sh
```

On first run it bootstraps, then prints:

```
factory: worktree at .git-factory/worktree
factory: run ./factory to start
```

### Run

```bash
./factory
```

Resumes where it left off. The agent works in the background; tool calls and costs are printed to the terminal.

### Dev mode

```bash
bash factory.sh dev        # fresh start every time (resets worktree + branch)
bash factory.sh dev reset  # tear down without running
```

### Destroy

```bash
./factory destroy
```

Removes `.git-factory/`, deletes the `factory` branch, restores `factory.sh`, and removes the `./factory` launcher. Prompts for confirmation.

## Requirements

- `claude` CLI on `PATH` ([Claude Code](https://docs.anthropic.com/en/docs/claude-code))
- `git`
- `python3`
- `bash`

## How the agent operates

The agent's behavior is defined entirely by the `CLAUDE.md` in the worktree. After bootstrap, this file contains:

- **Purpose** — what "better" means for your codebase, at existential, strategic, and operational levels
- **Measures** — observable signals of progress
- **Tests** — gate questions the agent asks before every change

The agent reads your source repo's `CLAUDE.md` and `README.md` to understand what it's working with, then writes these sections based on what it finds.

## Design decisions

- **Git worktree isolation** — the agent works on its own branch in its own directory. Your working tree and branch are never touched.
- **No config files** — everything is self-contained in `factory.sh`. No `.env`, no `config.yaml`, no external dependencies beyond claude + git + python.
- **Self-replacing installer** — `factory.sh` is a one-shot installer that replaces itself with a tiny launcher script. The original is preserved in the worktree for `./factory destroy` to restore.
- **Headless Claude** — runs with `--dangerously-skip-permissions` in print mode. No interactive prompts, no TUI. Tool calls are streamed as JSON and logged to the terminal.
- **Local-only git ignore** — uses `.git/info/exclude` instead of `.gitignore` so factory artifacts never pollute your repo's tracked files.
