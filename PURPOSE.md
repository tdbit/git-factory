# Purpose

## Existential Purpose

- Developers can drop a single file into any git repository and have an AI agent autonomously improve the codebase without ever touching their working directory or requiring configuration.
- Development teams maintain software quality and architectural coherence over time with less manual code review and planning overhead.
- Software repositories accumulate improvements continuously without requiring explicit task creation or human orchestration of each change.
- Maintenance friction decreases as the system learns why changes matter, not just what changes to make.

## Strategic Purpose

- The agent's decisions trace back to explicit Purpose (Existential, Strategic, Tactical), making improvements predictable and aligned with what the software is actually for rather than arbitrary code changes.
- Task completion conditions are strict and automatable, preventing silent failures where the agent produces commits that look good but don't actually satisfy requirements.
- Work is structured hierarchically (initiatives → projects → tasks) so that large improvements decompose into shippable pieces without requiring a human planner to orchestrate the breakdown.
- Project worktrees isolate agent work on separate branches, eliminating the risk of corrupting a developer's working tree or main branch while the agent operates.
- The system self-corrects by analyzing failures as violations of stated Measures and Tests, then fixing the system rather than retrying the same work with the same constraints.
- Multi-agent support (Claude, Codex) lets the system continue operating even when one provider is unavailable or changes its pricing/terms, decoupling the factory from a single vendor.
- A standalone `.factory/` git repo keeps all metadata separate from the source repo's tracked files, allowing the factory to bootstrap and operate without polluting `.gitignore` or creating merge conflicts.

## Tactical Purpose

- `factory.sh` is a ~1800-line bash/Python file that contains all logic to bootstrap and run, making installation trivial (one file drop, one command) and auditable end-to-end without hunting through package dependencies.
- The task completion system (`check_done()` in `factory.py:310–365`) uses only literal string matching and basic command execution, but lacks conditions like `section_exists()` and `no_section()` which are documented but not implemented, creating a gap between spec and implementation.
- Task prompts must include the agent's acceptance criteria (Done conditions) in the prompt itself via `## Acceptance Criteria`, but this logic only fires if the task has non-empty Done conditions — the system doesn't surface this to the agent when conditions are missing or malformed.
- The planner's quality gate (Step 4 in `PLANNING.md`) asks "Can I trace this to a specific Purpose bullet?" but `PURPOSE.md` doesn't exist until after the first task, leaving the planner with no reference for the first planning cycle.
- The failure analysis protocol (`FAILURE.md`) requires the agent to distinguish Existential/Strategic/Tactical failures and prescribe fixes, but provides no concrete examples of what each looks like, increasing risk of vague or misdirected fixes.
- Scarcity invariants (1 active initiative, ≤2 active projects, ≤3 active tasks, ≤1 active unparented task) are documented in three places with slightly different wording, creating risk of inconsistent enforcement.
- The epilogue template (`EPILOGUE.md`) is appended to project task prompts but its exact format and intended placement in the prompt is not defined, leaving room for inconsistent injection.

---

# Measures

## Existential Measures

- Agent completes a full bootstrap sequence and produces at least one committed improvement to the codebase without manual intervention: `git log --oneline | head -20` shows commits authored by the agent.
- A developer can drop `factory.sh` into a fresh repo, run `bash factory.sh`, and after bootstrap run `./factory` and observe the agent working without leaving the repository in an invalid state: `git status` remains clean in the working tree.
- The system produces improvements that satisfy stated Purpose measures within a reasonable operational window (e.g., one run completes in under 60 minutes) rather than timing out or hanging.
- Project worktrees remain clean and isolated: `git worktree list` shows only active worktrees, and checking out a worktree allows independent agent work without interfering with other worktrees or the working tree.

## Strategic Measures

- Every active task has a `## Done` section with at least one completion condition, and the runner verifies it exists before running the task: scan active tasks for missing or empty Done sections.
- Task prompts include the full acceptance criteria inline (from `## Acceptance Criteria` injected in `factory.py:857–860`): read the last run log and confirm the prompt text includes `` `file_contains(...)` `` etc.
- The failure analysis protocol is followed when a task fails: stopped tasks have a follow-up task created with `author: fixer` and that task targets a factory system file (`.py`, `.md`, or config).
- The three scarcity invariants are checked and enforced in the same place (`PLANNING.md` Step 4) with identical wording to reduce the risk of contradictory constraints being applied.
- At least two agent CLI providers are supported and can be invoked without requiring explicit configuration: `which claude` and `which codex` both succeed, and the system detects both automatically.
- Project worktrees created for different projects do not interfere: running two project tasks sequentially should leave each project's worktree in the correct branch state for its next task.

## Tactical Measures

- Bash syntax check passes: `bash -n factory.sh` exits 0.
- Python syntax check passes: `python3 -c "import ast; ast.parse(open('.factory/factory.py').read())"` exits 0.
- Bootstrap completes: after `bash factory.sh` on a fresh repo, `.factory/factory.py` exists and `.factory/tasks/` contains at least one task file dated today.
- All documented completion conditions are implemented: scan `factory.py` for each of `file_exists`, `file_absent`, `file_contains`, `file_missing_text`, `command`, and `always`, confirming all six appear in `check_one_condition()`.
- Task Done sections parse without errors: run a task with a malformed condition (e.g., `file_exists("path"` missing closing paren) and confirm the agent sees the unparseable condition in the log, not a silent skip.
- The planner reads `PURPOSE.md` when it exists and references it in validation (Step 4 of `PLANNING.md`): grep the planner task run log for `PURPOSE.md` or `Existential`.
- The epilogue is injected identically whether a task is project-scoped or factory-scoped: create two tasks (one with parent, one without) and confirm both see the epilogue in their prompts.
- Factory metadata commits use correct message prefixes: `git log --oneline | grep -E "^(Start|Complete|Incomplete|Failed) Task:"` shows all task lifecycle commits correctly prefixed.
- Scarcity invariants are respected after planning: after a full cycle (plan → task → complete), count active items and confirm 1 initiative, ≤2 projects, ≤3 tasks, ≤1 unparented task.

---

# Tests

## Existential Tests

- Does the agent produce a workable codebase improvement that traces back to the Purpose it wrote in bootstrap, or are the commits cosmetic changes unrelated to any stated goal?
- Can a developer check out a `factory/*` branch and see coherent, buildable code, or is the work incomplete, broken, or abandoned mid-task?
- Does the system avoid corrupting the developer's working tree and main branch even when tasks fail, agent crashes, or the system is killed mid-run?
- Would a code reviewer consider the agent's work a genuine improvement, not just a compliance exercise that followed instructions but didn't actually make the software better?

## Strategic Tests

- Is every active piece of work traceable to a specific Purpose bullet at the right level (Initiative → Existential/Strategic, Project → Strategic/Tactical, Task → Tactical)?
- Do task Done conditions actually measure what the task prompt claims to deliver, or are they aspirational, vague, or impossible to verify?
- Does the system self-correct when a task fails, or does it loop retrying the same failure until a human intervenes?
- Can a new developer understand the planning hierarchy (initiatives, projects, tasks) and the Purpose framework without reading external design docs?
- Are all three scarcity invariants enforced in the same way and location, or do conflicting constraints exist that could cause deadlock?

## Tactical Tests

- Does `bash -n factory.sh` pass? Does `python3 -m py_compile .factory/factory.py` pass after bootstrap?
- After bootstrap, does `cat .factory/PURPOSE.md` output a valid Purpose framework with Existential, Strategic, and Tactical sections for the factory and then the repo?
- Do all six completion condition types (`file_exists`, `file_absent`, `file_contains`, `file_missing_text`, `command`, `always`) produce correct True/False results when tested?
- When a task with a malformed Done condition runs, does the agent see the unparseable condition logged, or is it silently dropped?
- Does running a project task create a git worktree, create the correct branch, and leave it clean and on the correct branch when the task completes?
- After a failed task, is there a follow-up task created with `author: fixer` that targets a factory system file (not a retry of the original work)?
- Are the scarcity invariants (1 active initiative, ≤2 projects, ≤3 tasks, ≤1 unparented) enforceable by counting active items from file inspection?
- Does the agent's task prompt include the full Done conditions inline as `## Acceptance Criteria` when the task is prepared for execution?
- Are all factory lifecycle commits (Start, Complete, Incomplete, Failed) prefixed correctly and appear in `git log` in the right order?
