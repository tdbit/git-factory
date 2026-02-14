#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# --- dependency checks ---
for cmd in git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "\033[31mfactory:\033[0m error: '$cmd' is not installed." >&2
    exit 1
  fi
done

REPO="$(basename "$ROOT")"
BRANCH="factory/$REPO"
FACTORY_DIR="${ROOT}/.git-factory"
WORKTREE="${FACTORY_DIR}/worktree"
PROJECT_WORKTREES="${FACTORY_DIR}/worktrees"
PY_NAME="factory.py"

# --- ensure .git-factory dir is ignored locally ---
DEV_MODE=false
if [[ "${1:-}" == "dev" ]]; then
  DEV_MODE=true
  shift
fi

# --- dev reset: tear down without restoring factory.sh ---
dev_reset() {
  # safety check: ensure FACTORY_DIR looks right
  if [[ -z "$FACTORY_DIR" ]] || [[ "$FACTORY_DIR" != *".git-factory" ]]; then
    echo "Error: unsafe FACTORY_DIR: $FACTORY_DIR"
    exit 1
  fi

  # remove project worktrees under .git-factory/worktrees/
  if [[ -d "$FACTORY_DIR/worktrees" ]]; then
    for wt in "$FACTORY_DIR/worktrees"/*/; do
      [[ -d "$wt" ]] && git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    done
  fi

  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
  rm -rf "$FACTORY_DIR"

  # delete factory branches: factory/<repo> + any project branches factory/*
  git for-each-ref --format='%(refname:short)' 'refs/heads/factory/' | while read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
  done
  rm -f "$ROOT/factory"
}

if [[ "$DEV_MODE" == true ]] && [[ "${1:-}" == "reset" ]]; then
  dev_reset
  echo -e "\033[33mfactory:\033[0m reset"
  exit 0
fi

# --- dev mode: always start fresh ---
if [[ "$DEV_MODE" == true ]] && [[ -d "$FACTORY_DIR" ]]; then
  echo -e "\033[33mfactory:\033[0m resetting"
  dev_reset
fi

EXCLUDE_FILE="$ROOT/.git/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
touch "$EXCLUDE_FILE"
if ! grep -qxF "/.git-factory/" "$EXCLUDE_FILE"; then
  printf "\n/.git-factory/\n" >> "$EXCLUDE_FILE"
fi

# --- create factory branch if missing ---
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git branch "$BRANCH"
  echo -e "\033[33mfactory:\033[0m created branch $BRANCH"
fi

# --- resume existing worktree or create fresh ---
if [[ "$DEV_MODE" == false ]] && [[ -d "$WORKTREE" ]] && [[ -f "$WORKTREE/$PY_NAME" ]]; then
  echo -e "\033[33mfactory:\033[0m resuming"
  cd "$WORKTREE"
  exec python3 "$PY_NAME"
fi

# --- fresh setup: create worktree ---
mkdir -p "$FACTORY_DIR"
if [[ -d "$WORKTREE" ]]; then
  git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$WORKTREE" >/dev/null 2>&1 || true
fi
git worktree add "$WORKTREE" "$BRANCH" >/dev/null 2>&1

# --- detect default branch ---
DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")"

# --- write python runner into worktree ---
for d in tasks hooks state agents initiatives projects; do
  mkdir -p "$WORKTREE/$d"
done
mkdir -p "$PROJECT_WORKTREES"
printf "%s\n" "$DEFAULT_BRANCH" > "$WORKTREE/state/default_branch.txt"
printf "%s\n" "$PROJECT_WORKTREES" > "$WORKTREE/state/project_worktrees.txt"
cat > "$WORKTREE/$PY_NAME" <<'PY'
#!/usr/bin/env python3
import os, sys, re, signal, time, shutil, subprocess, ast
from pathlib import Path

import atexit

ROOT = Path(__file__).resolve().parent
def _detect_branch():
    env = os.environ.get("FACTORY_BRANCH", "").strip()
    if env:
        return env
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=Path(__file__).resolve().parent,
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return "factory/repo"

BRANCH = _detect_branch()
TASKS_DIR = ROOT / "tasks"
AGENTS_DIR = ROOT / "agents"
INITIATIVES_DIR = ROOT / "initiatives"
PROJECTS_DIR = ROOT / "projects"
STATE_DIR = ROOT / "state"
# parent repo git dir — ROOT is .git-factory/worktree, so parent is two levels up
PARENT_REPO = ROOT.parent.parent

def _get_default_branch():
    p = STATE_DIR / "default_branch.txt"
    if p.exists():
        val = p.read_text().strip()
        if val:
            return val
    return "main"

def project_slug(project_path):
    """Extract slug from projects/YYYY-MM-slug.md -> slug."""
    name = Path(project_path).stem  # YYYY-MM-slug
    return re.sub(r"^\d{4}-\d{2}-", "", name)

def project_branch_name(project_path):
    return f"factory/{project_slug(project_path)}"

def _get_project_worktrees_dir():
    p = STATE_DIR / "project_worktrees.txt"
    if p.exists():
        val = p.read_text().strip()
        if val:
            return Path(val)
    return ROOT.parent / "worktrees"

def project_worktree_dir(project_path):
    return _get_project_worktrees_dir() / project_slug(project_path)

def ensure_project_worktree(project_path):
    """Create project branch (off default branch) and worktree if needed."""
    slug = project_slug(project_path)
    branch = project_branch_name(project_path)
    wt_dir = project_worktree_dir(project_path)
    default_branch = _get_default_branch()

    def _git(*args):
        return subprocess.check_output(
            ["git"] + list(args),
            cwd=PARENT_REPO,
            stderr=subprocess.STDOUT,
        ).decode().strip()

    # create branch if missing
    try:
        _git("show-ref", "--verify", "--quiet", f"refs/heads/{branch}")
    except subprocess.CalledProcessError:
        _git("branch", branch, default_branch)
        log(f"created branch {branch} off {default_branch}")

    # create worktree if missing or stale
    if wt_dir.exists():
        # check if git considers it valid
        try:
            wt_list = _git("worktree", "list", "--porcelain")
            if str(wt_dir.resolve()) not in wt_list:
                _git("worktree", "remove", "--force", str(wt_dir))
                wt_dir.mkdir(parents=True, exist_ok=True)
                _git("worktree", "add", str(wt_dir), branch)
                log(f"re-created stale worktree {slug}")
        except subprocess.CalledProcessError:
            pass
    else:
        wt_dir.parent.mkdir(parents=True, exist_ok=True)
        _git("worktree", "add", str(wt_dir), branch)
        log(f"created worktree {slug} at {wt_dir}")

    return wt_dir

def build_epilogue(task, project_dir):
    """Build epilogue instruction appended to project task prompts."""
    task_path = task["_path"]
    return f"""

---

## Epilogue (runner instructions — follow these exactly)

You are working in a project worktree at `{project_dir}`.
Your code changes go here. The factory orchestration lives in a separate worktree.

When you are done:
1. Stage and commit your code changes in this worktree (the current directory).
   Use a short, descriptive commit message.
2. Get the final commit hash: `git rev-parse HEAD`
3. Update the task file at `{task_path}` — add `project_commit: <hash>` to the
   frontmatter (after the last existing field, before the closing `---`).
   Use: `python3 -c "
p = __import__('pathlib').Path('{task_path}')
t = p.read_text()
_, fm, body = t.split('---', 2)
fm = fm.rstrip() + '\\nproject_commit: <HASH>\\n'
p.write_text('---' + fm + '---' + body)
"` (replace <HASH> with the actual hash)
4. Commit that metadata change in the factory worktree:
   `git -C {ROOT} add {task_path.relative_to(ROOT)} && git -C {ROOT} commit -m "Record project commit for {task['name']}"`
5. Stop.
"""

def log(msg):
    print(f"\033[33mfactory:\033[0m {msg}", flush=True)

def sh(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()

def _cleanup_pid():
    pid_file = STATE_DIR / "factory.pid"
    try:
        pid_file.unlink(missing_ok=True)
    except OSError:
        pass

def _handle_signal(signum, frame):
    _cleanup_pid()
    log(f"received signal {signum}, exiting")
    raise SystemExit(128 + signum)

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, _handle_signal)
atexit.register(_cleanup_pid)

# --- cached CLI lookup ---
_cli_cache = None

def get_agent_cli():
    global _cli_cache
    if _cli_cache is not None:
        return _cli_cache
    for cmd in ("codex", "claude", "claude-code"):
        path = shutil.which(cmd)
        if path:
            _cli_cache = (cmd, path)
            return _cli_cache
    log("no supported agent CLI found on PATH (tried: codex, claude, claude-code)")
    return None

def init():
    cli = get_agent_cli()
    if not cli:
        return 1
    cli_name, cli_path = cli
    branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
    if branch != BRANCH:
        log(f"not on factory branch ({BRANCH}): {branch}")
        return 2
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    AGENTS_DIR.mkdir(exist_ok=True)
    INITIATIVES_DIR.mkdir(exist_ok=True)
    PROJECTS_DIR.mkdir(exist_ok=True)
    (STATE_DIR / "initialized.txt").write_text(time.ctime() + "\n")
    (STATE_DIR / "agent_cli_name.txt").write_text(cli_name + "\n")
    (STATE_DIR / "agent_cli_path.txt").write_text(cli_path + "\n")
    # back-compat for older tooling that reads this file name
    (STATE_DIR / "claude_path.txt").write_text(cli_path + "\n")
    return 0

# --- helpers ---

def load_agent(name):
    """Load an agent definition from agents/{name}.md."""
    path = AGENTS_DIR / f"{name}.md"
    if not path.exists():
        return None
    text = path.read_text()
    if not text.startswith("---"):
        return {"name": name, "prompt": text, "tools": "Read,Write,Edit,Bash,Glob,Grep"}
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {"name": name, "prompt": text, "tools": "Read,Write,Edit,Bash,Glob,Grep"}
    _, fm, body = parts
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        if key.strip():
            meta[key.strip()] = val.strip()
    return {
        "name": name,
        "prompt": body.strip(),
        "tools": meta.get("tools", "Read,Write,Edit,Bash,Glob,Grep"),
    }


# --- task parsing ---

def parse_task(path):
    text = path.read_text()
    if not text.startswith("---"):
        log(f"skipping {path.name}: no frontmatter")
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        log(f"skipping {path.name}: malformed frontmatter")
        return None
    _, fm, body = parts
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        if key.strip():
            meta[key.strip()] = val.strip()
    # parse sections from body
    sections = {}
    current_section = None
    current_lines = []
    prompt_lines = []
    for line in body.split("\n"):
        m = re.match(r'^##\s+(.+)$', line)
        if m:
            if current_section:
                sections[current_section] = "\n".join(current_lines).strip()
            current_section = m.group(1).strip().lower()
            current_lines = []
        elif current_section:
            current_lines.append(line)
        else:
            prompt_lines.append(line)
    if current_section:
        sections[current_section] = "\n".join(current_lines).strip()
    # extract done conditions from ## Done section
    done_lines = []
    if "done" in sections:
        for line in sections["done"].splitlines():
            line = line.strip().lstrip("- ")
            if line and re.match(r'`?(\w+)\(', line):
                done_lines.append(line.strip('`'))
            elif line == "always" or line == "`always`":
                done_lines.append("always")
    name = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", path.stem)
    return {
        "name": name,
        "tools": meta.get("tools", "Read,Write,Edit,Bash,Glob,Grep"),
        "status": meta.get("status", ""),
        "agent": meta.get("agent", ""),
        "parent": meta.get("parent", ""),
        "previous": meta.get("previous", ""),
        "done": done_lines,
        "prompt": "\n".join(prompt_lines).strip(),
        "sections": sections,
        "_path": path,
    }

def load_tasks():
    tasks = []
    if TASKS_DIR.exists():
        for f in sorted(TASKS_DIR.glob("*.md")):
            t = parse_task(f)
            if t:
                tasks.append(t)
    return tasks

def update_task_meta(task, **kwargs):
    path = task["_path"]
    text = path.read_text()
    _, fm, body = text.split("---", 2)
    lines = fm.strip().splitlines()
    existing = {}
    for i, line in enumerate(lines):
        key, _, _ = line.partition(":")
        existing[key.strip()] = i
    for key, val in kwargs.items():
        if key in existing:
            lines[existing[key]] = f"{key}: {val}"
        else:
            lines.append(f"{key}: {val}")
    path.write_text("---\n" + "\n".join(lines) + "\n---" + body)

# --- completion checks ---

def check_one_condition(cond, target_dir=None):
    base = target_dir or ROOT
    if not cond:
        return False
    if cond == "always":
        return False
    m = re.match(r'(\w+)\((.+)\)$', cond)
    if not m:
        log(f"unknown condition: {cond}")
        return False
    func, raw_args = m.group(1), m.group(2)
    try:
        if not raw_args.strip():
            args = []
        else:
            parsed = ast.literal_eval(f"({raw_args})")
            args = [parsed] if isinstance(parsed, str) else list(parsed)
    except (ValueError, SyntaxError):
        log(f"check parse error: {cond}")
        return False
    # section_exists/no_section always check the factory CLAUDE.md
    if func == "section_exists":
        text = (ROOT / "CLAUDE.md").read_text() if (ROOT / "CLAUDE.md").exists() else ""
        return args[0] in text
    elif func == "no_section":
        text = (ROOT / "CLAUDE.md").read_text() if (ROOT / "CLAUDE.md").exists() else ""
        return args[0] not in text
    elif func == "file_exists":
        pat = args[0]
        glob_pat = pat.replace("YYYY-MM-DD", "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]").replace("YYYY", "[0-9][0-9][0-9][0-9]")
        has_wild = any(ch in glob_pat for ch in "*?[]")
        if has_wild or "YYYY" in pat:
            return any(base.glob(glob_pat))
        return (base / pat).exists()
    elif func == "file_absent":
        pat = args[0]
        glob_pat = pat.replace("YYYY-MM-DD", "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]").replace("YYYY", "[0-9][0-9][0-9][0-9]")
        has_wild = any(ch in glob_pat for ch in "*?[]")
        if has_wild or "YYYY" in pat:
            return not any(base.glob(glob_pat))
        return not (base / pat).exists()
    elif func == "file_contains":
        p = base / args[0]
        return p.exists() and args[1] in p.read_text()
    elif func == "file_missing_text":
        p = base / args[0]
        return not p.exists() or args[1] not in p.read_text()
    elif func == "command":
        try:
            subprocess.run(args[0], shell=True, cwd=base, check=True, capture_output=True)
            return True
        except subprocess.CalledProcessError:
            return False
    log(f"unknown check: {func}")
    return False

def check_done(done, target_dir=None):
    """Check a list of done conditions. All must pass."""
    if not done:
        return False
    return all(check_one_condition(c, target_dir) for c in done)

def check_done_details(done, target_dir=None):
    """Return (all_passed, [(cond, passed), ...])."""
    results = []
    if not done:
        return False, results
    all_passed = True
    for cond in done:
        ok = check_one_condition(cond, target_dir)
        results.append((cond, ok))
        if not ok:
            all_passed = False
    return all_passed, results

def next_task():
    tasks = load_tasks()
    # skip tasks that are terminal — completed/stopped live in git history
    eligible = [t for t in tasks if t["status"] not in ("completed", "stopped")]
    done_map = {t["_path"].name: check_done(t["done"]) for t in eligible}
    for t in eligible:
        if done_map.get(t["_path"].name):
            continue
        prev = t.get("previous", "").removeprefix("tasks/")
        if prev and not done_map.get(prev, False):
            continue
        return t
    return None

# --- agent runner ---

AGENT_TIMEOUT = float(os.environ.get("FACTORY_TIMEOUT_SEC", "0")) or None

def _kill_proc(proc, reason="timeout"):
    """Terminate a subprocess gracefully, then force-kill after 5s."""
    log(f"killing agent ({reason})")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

def _open_run_log(task_name=None):
    """Open a JSONL log file for the current agent run."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = STATE_DIR / "last_run.jsonl"
    f = open(log_path, "w")
    if task_name:
        import json as _json
        f.write(_json.dumps({"type": "_factory", "task": task_name, "time": time.ctime()}) + "\n")
    return f

def _build_prompt(prompt, allowed_tools, agent):
    full_prompt = prompt
    tools = allowed_tools
    if agent and agent.get("prompt"):
        full_prompt = f"{agent['prompt']}\n\n---\n\n{prompt}"
        if agent.get("tools"):
            tools = agent["tools"]
    return full_prompt, tools

def run_codex(prompt, allowed_tools="Read,Write,Edit,Bash,Glob,Grep", agent=None, cli_path=None, cwd=None, run_log=None):
    import threading, json as _json
    cli_path = cli_path or shutil.which("codex")
    if not cli_path:
        log("codex CLI not found on PATH")
        return False, None
    work_dir = cwd or ROOT

    full_prompt, allowed_tools = _build_prompt(prompt, allowed_tools, agent)

    requested_model = os.environ.get("FACTORY_CODEX_MODEL", "").strip()
    fallback_models = [
        m.strip() for m in os.environ.get("FACTORY_CODEX_MODEL_FALLBACKS", "gpt-5-codex,o3").split(",")
        if m.strip()
    ]
    model_candidates = []
    if requested_model:
        model_candidates.append(requested_model)
    else:
        model_candidates.append("gpt-5.2-codex")
    for m in fallback_models:
        if m not in model_candidates:
            model_candidates.append(m)

    last_stderr = b""
    heartbeat_sec = float(os.environ.get("FACTORY_HEARTBEAT_SEC", "15"))
    for model_name in model_candidates:
        log(f"agent provider: codex, model: {model_name}")
        proc = subprocess.Popen(
            [cli_path, "exec", "--model", model_name, "--json", full_prompt],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            cwd=work_dir,
        )
        start = time.monotonic()
        last_output = [start]
        stderr_lines = []

        stdout_garbage = []
        progress_len = 0
        prefix = "\033[33mfactory:\033[0m "

        def _handle_event(ev):
            nonlocal progress_len
            etype = ev.get("type")
            item = ev.get("item") or {}
            # shorten long commands to first line
            cmd_val = item.get("command") or ""
            if cmd_val:
                first = cmd_val.splitlines()[0]
                if cmd_val != first:
                    item["command"] = first + " …"
            if etype == "message":
                msg = ev.get("content") or ev.get("text") or ""
                if msg:
                    print(msg, end="")
                return
            if etype == "item.started":
                cmd = item.get("command") or ""
                if cmd:
                    line = f"{prefix}\033[36m→ Run\033[0m \033[2m{cmd}\033[0m"
                    progress_len = len(line)
                    sys.stdout.write(line)
                    sys.stdout.flush()
                return
            if etype == "item.completed":
                cmd = item.get("command") or ""
                out = item.get("aggregated_output") or ""
                exit_code = item.get("exit_code")
                if cmd:
                    status_prefix = "\033[36m✓ Run\033[0m" if exit_code == 0 else "\033[31m✗ Run\033[0m"
                    suffix = "" if exit_code == 0 else f" (exit {exit_code})"
                    line = f"{prefix}{status_prefix} \033[2m{cmd}\033[0m{suffix}"
                    pad = max(0, progress_len - len(line))
                    sys.stdout.write("\r" + line + (" " * pad) + "\n")
                    sys.stdout.flush()
                    progress_len = 0
                if out and exit_code != 0:
                    print(out, end="" if out.endswith("\n") else "\n")
                return
            if "content" in ev and isinstance(ev["content"], str):
                print(ev["content"], end="")

        def _read_stdout():
            for line in iter(proc.stdout.readline, b""):
                last_output[0] = time.monotonic()
                if line:
                    text = line.decode(errors="replace").strip()
                    if not text:
                        continue
                    if run_log:
                        run_log.write(text + "\n")
                        run_log.flush()
                    try:
                        ev = _json.loads(text)
                    except ValueError:
                        stdout_garbage.append(text)
                        continue
                    _handle_event(ev)

        def _read_stderr():
            for line in iter(proc.stderr.readline, b""):
                last_output[0] = time.monotonic()
                if line:
                    stderr_lines.append(line)

        t_out = threading.Thread(target=_read_stdout, daemon=True)
        t_err = threading.Thread(target=_read_stderr, daemon=True)
        t_out.start()
        t_err.start()

        last_seen = last_output[0]
        next_heartbeat = last_seen + heartbeat_sec
        deadline = start + AGENT_TIMEOUT if AGENT_TIMEOUT else None
        while proc.poll() is None:
            if last_output[0] != last_seen:
                last_seen = last_output[0]
                next_heartbeat = last_seen + heartbeat_sec
            now = time.monotonic()
            if deadline and now >= deadline:
                _kill_proc(proc, f"exceeded {AGENT_TIMEOUT:.0f}s timeout")
                return False, None
            if now >= next_heartbeat:
                elapsed = int(now - start)
                log(f"still working… {elapsed}s")
                next_heartbeat = now + heartbeat_sec
            time.sleep(0.2)

        t_out.join(timeout=1)
        t_err.join(timeout=1)

        if proc.returncode == 0:
            return True, None

        last_stderr = b"".join(stderr_lines).strip() or b""
        stderr_text = (last_stderr or b"").decode(errors="replace")
        retryable = (
            "does not exist or you do not have access" in stderr_text
            or "model_not_found" in stderr_text
            or "invalid model" in stderr_text.lower()
        )
        if retryable:
            log(f"codex model unavailable: {model_name}, trying fallback")
            continue

        log(f"codex failed with exit code {proc.returncode}")
        if stderr_text:
            log("--- stderr start ---")
            print(stderr_text, end="")
            log("--- stderr end ---")
        if stdout_garbage:
            log("--- stdout garbage start ---")
            for line in stdout_garbage:
                print(line)
            log("--- stdout garbage end ---")
        return False, None

    log("codex failed for all configured models")
    if last_stderr:
        log("--- stderr start ---")
        print(last_stderr.decode(errors="replace"), end="")
        log("--- stderr end ---")
    return False, None


def run_claude(prompt, allowed_tools="Read,Write,Edit,Bash,Glob,Grep", agent=None, cli_path=None, cli_name=None, cwd=None, run_log=None):
    import json as _json, threading
    cli_path = cli_path or shutil.which(cli_name or "claude")
    if not cli_path:
        log("claude CLI not found on PATH")
        return False, None
    work_dir = cwd or ROOT

    full_prompt, allowed_tools = _build_prompt(prompt, allowed_tools, agent)

    model_arg = []
    model_name = os.environ.get("FACTORY_CLAUDE_MODEL", "").strip()
    if model_name:
        model_arg = ["--model", model_name]
        log(f"agent provider: {cli_name or 'claude'}, model: {model_name}")
    else:
        log(f"agent provider: {cli_name or 'claude'}, model: default")

    proc = subprocess.Popen(
        [cli_path, "--dangerously-skip-permissions", "-p", "--verbose",
         "--output-format", "stream-json",
         full_prompt, "--allowedTools", allowed_tools, *model_arg],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, # Capture stderr
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=work_dir,
    )
    session_id = None
    stderr_output = []
    
    def read_stderr():
        for line in iter(proc.stderr.readline, b""):
            line = line.decode().strip()
            if line:
               stderr_output.append(line)

    stderr_reader = threading.Thread(target=read_stderr, daemon=True)
    stderr_reader.start()
    stdout_garbage = []
    def read_stream():
        nonlocal session_id
        for raw in iter(proc.stdout.readline, b""):
            raw = raw.strip()
            if not raw:
                continue
            if run_log:
                run_log.write(raw.decode(errors="replace") + "\n")
                run_log.flush()
            try:
                ev = _json.loads(raw)
            except ValueError:
                stdout_garbage.append(raw.decode(errors='replace'))
                continue
            t = ev.get("type", "")
            if t == "assistant":
                for block in ev.get("message", {}).get("content", []):
                    if block.get("type") == "tool_use":
                        name = block.get("name", "")
                        if not name:
                            continue
                        inp = block.get("input", {})
                        detail = ""
                        if name in ("Read", "Write", "Edit"):
                            fp = inp.get("file_path", "")
                            if fp:
                                detail = fp.rsplit("/", 1)[-1]
                        elif name == "Glob":
                            detail = inp.get("pattern", "")
                        elif name == "Grep":
                            detail = inp.get("pattern", "")
                        elif name == "Bash":
                            cmd = inp.get("command", "")
                            detail = cmd[:120] + ("…" if len(cmd) > 120 else "")
                        if detail:
                            log(f"\033[36m→ {name}\033[0m \033[2m{detail}\033[0m")
                        else:
                            log(f"\033[36m→ {name}\033[0m")
            elif t == "result":
                session_id = ev.get("session_id", session_id)
                cost = ev.get("cost_usd") or ev.get("total_cost_usd")
                dur = ev.get("duration_ms")
                parts = []
                if dur:
                    parts.append(f"{dur/1000:.1f}s")
                if cost:
                    parts.append(f"${cost:.4f}")
                if parts:
                    log("\033[2m" + ", ".join(parts) + "\033[0m")
    reader = threading.Thread(target=read_stream, daemon=True)
    reader.start()
    start = time.monotonic()
    deadline = start + AGENT_TIMEOUT if AGENT_TIMEOUT else None
    try:
        while reader.is_alive() or stderr_reader.is_alive():
             if deadline and time.monotonic() >= deadline:
                 _kill_proc(proc, f"exceeded {AGENT_TIMEOUT:.0f}s timeout")
                 return False, session_id
             reader.join(timeout=0.5)
             stderr_reader.join(timeout=0.5)

        exit_code = proc.wait()
        if exit_code != 0:
            log(f"claude failed with exit code {exit_code}")
            if stderr_output:
                log("--- stderr start ---")
                for line in stderr_output:
                    print(line)
                log("--- stderr end ---")
            if stdout_garbage:
                log("--- stdout garbage start ---")
                for line in stdout_garbage:
                    print(line)
                log("--- stdout garbage end ---")
        return exit_code == 0, session_id
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        print()
        log("stopped")
        return False, session_id


def run_agent(prompt, allowed_tools="Read,Write,Edit,Bash,Glob,Grep", agent=None, cwd=None, run_log=None):
    cli = get_agent_cli()
    if not cli:
        return False, None
    cli_name, cli_path = cli
    if cli_name == "codex":
        return run_codex(prompt, allowed_tools, agent, cli_path, cwd=cwd, run_log=run_log)
    return run_claude(prompt, allowed_tools, agent, cli_path, cli_name, cwd=cwd, run_log=run_log)

# --- task planning ---

PLAN_PROMPT = """\
You are the factory's planning agent.

Your job is to allocate focus and create exactly one next task.

You operate over three flat levels of structure (each is a folder of markdown files):
- Initiatives (initiatives/)
- Projects (projects/)
- Tasks (tasks/)

Relationships are defined by frontmatter fields.

# Invariants (Must Always Hold)
- Exactly 1 active initiative
- At most 2 active projects
- At most 3 active tasks
- At most 1 active unparented (factory) task

If these constraints are violated, fix them before creating anything new.

# Read-Set Rule
When planning, only read items with status ∈ (active, backlog, suspended).
Ignore completed and stopped items unless explicitly debugging regressions.

# Planning Order
1. Ensure invariants hold.
2. Prefer refinement over creation.
3. Only create new structure if necessary.
4. Write exactly one task.
5. Never create multiple tasks in a single planning run.

# Selection Logic
1. If there is a ready active task, do nothing.
2. If no active initiative exists:
   - Promote exactly one backlog initiative to active.
   - If none exist, create up to 3 backlog initiatives and activate exactly one.
3. If the active initiative has no active project:
   - Promote one backlog project under it.
   - If none exist, create exactly one backlog project under it and activate it.
4. If the active project has no ready tasks:
   - Create 1–3 backlog tasks under it.
   - Activate exactly one.

Unparented tasks are factory maintenance tasks. At most one may be active at any time.

# Task Creation Rules
When writing a task:
- Atomic, completable in one session.
- Names specific files/functions/behaviors.
- Produces observable change.
- Includes strict Done conditions.
- Advances the active project (or is an unparented factory task).
- Does not create parallel structure.

Never create more than one task.

# Output
Create exactly one file in tasks/ named {today}-slug.md.

Format:
```markdown
---
tools: Read,Write,Edit,Bash
parent: projects/name.md   # omit if factory maintenance task
previous: YYYY-MM-DD-other.md   # optional
---

Concrete instruction.

## Done
- `file_exists(...)`
...
```

Do NOT commit. The runner will commit your work.
"""

def plan_next_task():
    today = time.strftime("%Y-%m-%d")
    prompt = PLAN_PROMPT.replace("{today}", today)
    # snapshot existing task files before planning
    before = set(f.name for f in TASKS_DIR.glob("*.md")) if TASKS_DIR.exists() else set()
    log("planning next task")
    run_log = _open_run_log("planning")
    try:
        ok, session_id = run_agent(prompt, run_log=run_log)
    finally:
        run_log.close()
    if not ok:
        log("planning failed")
        return False
    # find new task files and commit with proper message
    after = set(f.name for f in TASKS_DIR.glob("*.md")) if TASKS_DIR.exists() else set()
    new_tasks = sorted(after - before)
    try:
        sh("git", "add", "-A")
        if new_tasks:
            name = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", Path(new_tasks[0]).stem)
            sh("git", "commit", "-m", f"New Task: {name}")
            log(f"task planned: {name}")
        else:
            # agent may have modified existing files without creating a new task
            status = sh("git", "status", "--porcelain")
            if status:
                sh("git", "commit", "-m", "Planning update")
            log("task planned")
    except subprocess.CalledProcessError:
        log("task planned (nothing to commit)")
    return True

# --- main loop ---

def run():
    cli = get_agent_cli()
    if not cli:
        return

    TASKS_DIR.mkdir(exist_ok=True)
    STATE_DIR.mkdir(exist_ok=True)

    pid_file = STATE_DIR / "factory.pid"
    if pid_file.exists():
        try:
            old_pid = int(pid_file.read_text().strip())
            os.kill(old_pid, 0)  # check if process is alive
            log(f"another instance is running (pid {old_pid})")
            return
        except (ValueError, ProcessLookupError, PermissionError):
            pass  # stale pid file, safe to overwrite
    pid_file.write_text(str(os.getpid()) + "\n")

    def commit_task(task, message, scoop=False, reset=False, work_dir=None):
        """Commit task metadata on the factory branch.

        scoop=True:  best-effort stage any uncommitted agent work.
        reset=True:  discard uncommitted changes (for crashed agents).
        work_dir:    project worktree (if set, scoop/reset target the project
                     worktree instead of factory; only the task file is committed
                     on the factory branch).
        """
        is_project = work_dir is not None and work_dir != ROOT
        if reset:
            target = work_dir or ROOT
            try:
                subprocess.check_output(["git", "checkout", "--", "."], cwd=target, stderr=subprocess.STDOUT)
                subprocess.check_output(["git", "clean", "-fd"], cwd=target, stderr=subprocess.STDOUT)
            except Exception:
                pass
        elif scoop and not is_project:
            # only scoop in factory worktree for non-project tasks
            try:
                status = sh("git", "status", "--porcelain")
                if status:
                    sh("git", "add", "-A")
            except Exception:
                pass
        rel = task["_path"].relative_to(ROOT)
        sh("git", "add", str(rel))
        sh("git", "commit", "-m", message)

    while True:
        task = next_task()
        if task is None:
            if not plan_next_task():
                log("stopping — planning failed")
                return
            continue
        name = task["name"]
        log(f"task: {name}")

        # determine work directory: project worktree or factory worktree
        is_project_task = task["parent"].startswith("projects/")
        if is_project_task:
            work_dir = ensure_project_worktree(task["parent"])
            log(f"project worktree: {work_dir}")
        else:
            work_dir = ROOT

        branch = sh("git", "rev-parse", "--abbrev-ref", "HEAD")
        update_task_meta(task, status="active", pid=str(os.getpid()), branch=branch)
        commit_task(task, f"Start Task: {name}")
        # build prompt: instruction body + context + verify (exclude done)
        prompt_parts = [task["prompt"]]
        for section in ("context", "verify"):
            if section in task["sections"]:
                prompt_parts.append(f"## {section.title()}\n\n{task['sections'][section]}")
        prompt = "\n\n".join(prompt_parts)

        # append epilogue for project tasks
        if is_project_task:
            prompt += build_epilogue(task, work_dir)

        # Load agent if specified
        agent_def = None
        if task.get("agent"):
            agent_name = task["agent"].replace("agents/", "").replace(".md", "")
            agent_def = load_agent(agent_name)
            if agent_def:
                log(f"using agent: {agent_name}")

        run_log = _open_run_log(name)
        try:
            ok, session_id = run_agent(prompt, allowed_tools=task["tools"], agent=agent_def, cwd=work_dir, run_log=run_log)
        finally:
            run_log.close()
        log(f"run log: {STATE_DIR / 'last_run.jsonl'}")
        if session_id:
            update_task_meta(task, session=session_id)
        if not ok:
            update_task_meta(task, status="stopped", stop_reason="failed")
            commit_task(task, f"Failed Task: {name}", reset=True, work_dir=work_dir if is_project_task else None)
            log(f"task failed: {name}")
            return
        passed, details = check_done_details(task["done"], target_dir=work_dir)
        if passed:
            if is_project_task:
                # capture commit from project worktree
                commit = subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=work_dir, stderr=subprocess.STDOUT
                ).decode().strip()
            else:
                commit = sh("git", "rev-parse", "HEAD")
            update_task_meta(task, status="completed", commit=commit)
            commit_task(task, f"Complete Task: {name}", scoop=True, work_dir=work_dir if is_project_task else None)
            log(f"task done: {name}")
        else:
            update_task_meta(task, status="suspended")
            commit_task(task, f"Incomplete Task: {name}", scoop=True, work_dir=work_dir if is_project_task else None)
            log(f"task did not complete: {name}")
            if details:
                log("done conditions:")
                for cond, ok in details:
                    mark = "✓" if ok else "✗"
                    log(f"  {mark} {cond}")
            log(f"task file: {task['_path'].name}")
            return

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        raise SystemExit(init())
    run()
PY
chmod +x "$WORKTREE/$PY_NAME"

# --- write CLAUDE.md (metadata only) ---
cat > "$WORKTREE/CLAUDE.md" <<CLAUDE
# Factory

Automated software factory for \`$REPO\`.

Source repo: \`$ROOT\`
Factory dir: \`$FACTORY_DIR\`
Worktree: \`$WORKTREE\`
Runner: \`factory.py\`
Initiatives: \`initiatives/\`
Projects: \`projects/\`
Tasks: \`tasks/\`
Agents: \`agents/\`
State: \`state/\`

You are a coding agent operating inside \`$FACTORY_DIR\`. You can only make 
changes to worktrees located in this directory.

The main factory worktree is \`$WORKTREE\` and the main branch is
\`$BRANCH\`.  This is where you track your work and the state of tasks,
projects, and initiatives.

Project-specific tasks for the source repo will have separate worktrees created
under \`$FACTORY_DIR/worktrees/\` each with its own branch prefixed with \`factory/\`. This
is where you will do the actual code changes related to the source repo.

Do not modify any files outside of these worktrees.

When you complete tasks, your commits will be merged back to the source repo by the runner.

## How tasks work

You are given one task at a time by the runner (\`factory.py\`). The task prompt
is your entire instruction for that run. You MUST follow these rules:

1. **Do the task.** Complete what the task prompt asks.
2. **Commit your work.** When you are done, \`git add\` and \`git commit\` the
   files you changed. Use a short, descriptive commit message that summarizes
   what you did — not the task name, not a prefix, just what changed.
3. **Branch naming.** If you create branches for task work, use names prefixed
   with \`factory/\` (for example \`factory/fix-task-parser\`).
4. **Do not modify this file beyond what a task asks.** If a task tells you to
   add sections to \`CLAUDE.md\`, do that. Otherwise leave it alone.
5. **Stop when done.** Do not loop, do not start the next task, do not look
   for more work. Complete your task, commit, and stop.


## Work Model

All work is organized in flat folders:

- \`initiatives/\`
- \`projects/\`
- \`tasks/\`

There is no folder nesting. Relationships are defined by frontmatter fields.

### Lifecycle (Uniform Everywhere)

All initiatives, projects, and tasks use the same lifecycle states:

- \`backlog\` — defined but not active
- \`active\` — currently in play
- \`suspended\` — intentionally paused
- \`completed\` — finished successfully
- \`stopped\` — ended and will not resume

There is no \`failed\` state.
Failure is represented as:
status: stopped
stop_reason: failed

### Structural Relationships

- \`parent:\` links a task → project or project → initiative.
- \`previous:\` defines sequential dependency between tasks.
- No \`parent\` means the task is a **factory maintenance task**.

### Scarcity Invariants (Must Always Hold)

The system maintains:

- Exactly **1 active initiative**
- At most **2 active projects**
- At most **3 active tasks**
- At most **1 active unparented (factory) task**

If these constraints are violated, fix them before creating new work.

### Read-Set Rule

When planning or selecting work, you may only read items with:

status ∈ (active, backlog, suspended)

You must ignore \`completed\` and \`stopped\` items unless explicitly investigating regressions.

Completed work lives in git history. It does not remain active context.

---

## Planning Discipline

Before creating new initiatives, projects, or tasks:

1. Check whether an active item already exists at that level.
2. Refine or extend existing work before creating parallel work.
3. Default to \`backlog\` when creating new items.
4. Activate exactly one new item per layer when required.

Creation is a last resort.
Refinement is preferred.

## Task format

Tasks are markdown files in \`tasks/\` named \`YYYY-MM-DD-slug.md\`. Every task
has YAML frontmatter for runner metadata, then a fixed set of markdown sections.

### Naming conventions (must follow)
- Initiatives: \`YYYY-slug.md\`
- Projects: \`YYYY-MM-slug.md\`
- Tasks: \`YYYY-MM-DD-slug.md\`

\`\`\`markdown
---
tools: Read,Write,Edit,Bash
parent: projects/name.md
previous: YYYY-MM-DD-other-task.md
---

What to do. This is the prompt — the agent's instruction for this run.
Be specific and concrete. Name files, functions, and behaviors.

## Done

Completion conditions checked by the runner after the agent finishes.
One condition per line. All must pass. Supported conditions:

- \\\`section_exists("text")\\\` — text appears in CLAUDE.md
- \\\`file_exists("path")\\\` — file exists in the worktree
- \\\`file_absent("path")\\\` — file does not exist
- \\\`file_contains("path", "text")\\\` — file contains text
- \\\`file_missing_text("path", "text")\\\` — file missing or lacks text
- \\\`command("cmd")\\\` — shell command exits 0
- \\\`always\\\` — task never completes (recurring)

## Context

Why this task exists. What purpose or measure it serves. Link to specific
items in the Purpose, Measures, or Tests sections of CLAUDE.md so the
agent understands how this work connects to the repo's goals.

## Verify

How the agent should check its own work before committing. Concrete
commands to run, files to inspect, behaviors to confirm. The agent
should do these checks — they are instructions, not just documentation.
\`\`\`

### Frontmatter fields

Author-set fields:

- **tools** — which Claude Code tools the agent can use (default:
  \`Read,Write,Edit,Bash,Glob,Grep\`)
- **parent** — project file this task advances (example: projects/2026-auth-hardening.md). Omit for factory maintenance tasks.
- **previous** — filename of a task that must complete first (dependency)

Runner-managed fields (set automatically, do not write these yourself):

- **status** — lifecycle state: \`backlog\`, \`active\`, \`suspended\`, \`completed\`, \`stopped\`
- **stop_reason** — required if \`status: stopped\`
- **pid** — process ID of the runner
- **session** — Claude session ID
- **branch** — git branch the task ran on
- **commit** — HEAD commit hash when the task completed

### Creating follow-up tasks

If your task creates follow-up tasks, set the \`parent\` field in the new
task's frontmatter to the filename of the current task so the runner
knows the dependency order.
CLAUDE

# --- write factory marker ---
printf "don't touch this\n" > "$WORKTREE/FACTORY.md"

# --- write bootstrap task ---
cat > "$WORKTREE/tasks/$(date +%Y-%m-%d)-define-purpose.md" <<'TASK'
---
tools: Read,Write,Edit,Bash
---

Read `CLAUDE.md` in this directory, then read the source repo's `CLAUDE.md`
and `README.md` (if they exist). The source repo path is in the CLAUDE.md
header.

Your task is to add three sections to this worktree's CLAUDE.md: **Purpose**,
**Measures**, and **Tests**.

Each section must include three levels of abstraction: **Existential**, **Strategic**, and **Tactical**.

- **Existential** — the real-world outcome this software exists to produce. Describe what becomes true for its users or domain when it is succeeding. Keep this concrete and outcome-focused, not about code aesthetics.
- **Strategic** — the kinds of improvements that compound over time in this repository. These define direction and leverage, not individual fixes.
- **Tactical** — specific, near-term improvements grounded in observable friction in this codebase. These should reference real files, workflows, or behaviors.

All levels must remain software-focused and grounded in what you observe in the repository. Avoid philosophical framing, abstract mission language, or organizational themes.

Keep the sections tight. Do not write essays.

Bullet guidance:
- **Existential**: 3–5 bullets.
- **Strategic**: 5–8 bullets.
- **Tactical**: 5–10 bullets.

Favor precision over volume. Each bullet should express a distinct idea.

### Purpose

The Purpose section defines what "better" means for this codebase.

**Existential Purpose** (3-5 bullets) — Define why this software exists in
terms of the real-world outcome it produces. What is true for its users or its
domain when this software is succeeding? If it's a tool for nurses: "Nurses
spend more time with patients and less time on paperwork." If it's a developer
tool: "Developers ship changes confidently with fewer manual steps." If it's an
automation system: "Routine decisions happen without human intervention." Keep
it concrete and tied to the people or problem the software serves. Do not
describe the character of the codebase here — that belongs in strategic purpose.

**Strategic Purpose** (5-8 bullets) — Define medium-term direction tied to
what you observe in the repo. Examples: reduce complexity in core paths,
improve developer ergonomics, prefer explicitness over magic, strengthen
invariants and contracts, eliminate sources of brittleness.

**Tactical Purpose** (5-10 bullets) — Define immediate, repo-specific
priorities. Be concrete and name areas of the repo. Examples: simplify a
confusing module, remove dead code, reduce test flakiness, improve error
messages, clarify public APIs, reduce steps to run locally.

---

### Measures

The Measures section defines signals of progress. Every measure must include
how it is observed — a command, a metric, or a concrete thing you can point at.

**Existential Measures** (3-5 bullets) — Indicators that the software is
fulfilling its reason for existing. These are not about code health — they are
about the real-world outcome the system was built to produce. If the repo is a
tool for healthcare nurses, examples might be: nurses spend less time on
charting, fewer tasks require manual data entry, shift handoffs take less time.
If it's a developer tool: developers ship faster, debugging takes fewer steps,
onboarding a new team member is easier. Tie these directly to the existential
purpose — what would be true in the world if this software were succeeding?

**Strategic Measures** (5-8 bullets) — Medium-term progress signals. Examples:
reduced complexity in core modules, faster test runs, fewer build steps,
clearer documentation, less coupling between subsystems.

**Tactical Measures** (5-10 bullets) — Concrete, checkable signals tied
directly to the tactical purpose. Each one should answer: "How do I know
this specific thing got better?" Examples: tests pass, lint clean, CI time
decreased by N seconds, fewer TODOs in module X, setup runs in fewer steps,
error message for Y now tells the user what to do, endpoint Z responds in
under N ms.

---

### Tests

The Tests section contains "purpose gate" questions. Ask yourself these
questions every time you make a change.

**Existential Tests** (3-5 bullets) — Does this change move the needle on the
real-world outcome the software exists to produce? Does it make the user's life
concretely better? Would the person this software serves notice or care about
this change? Does it bring the system closer to fulfilling its reason for
existing?

**Strategic Tests** (5-8 bullets) — Does this compound future improvements?
Does it reduce brittleness? Does it remove duplication? Does it improve
clarity in the most-used paths?

**Tactical Tests** (5-10 bullets) — Specific, answerable questions about
immediate outcomes. These should reference concrete commands, user actions, and
the tactical purpose and measures directly. Examples:

- What commands did you run to verify this works?
- Do all tests pass? Which test suites did you run?
- Does this make it easier for a user to [specific action]?
- Does this make [specific operation] faster or more reliable?
- Is the diff minimal for the behavior change achieved?
- Does this satisfy [specific tactical purpose item] according to
  [specific tactical measure]?
- Did you check that [specific thing] did not regress?
- Can a new contributor understand this change without extra context?
- Does the error output tell the user what went wrong and what to do?

After writing these sections, add them to this worktree's CLAUDE.md.

## Done

- `section_exists("## Purpose")`

## Context

This is the bootstrap task. It creates the Purpose, Measures, and Tests
sections that guide all future factory work. Without these sections, the
agent has no way to evaluate whether a change is worthwhile.

## Verify

- Confirm `CLAUDE.md` contains `## Purpose`, `## Measures`, and `## Tests`
  sections with Existential, Strategic, and Tactical subsections.
- Confirm each subsection has the right number of bullets (3-5 existential, 5-8 strategic, 5-10 tactical)
- Read the sections back and check they are grounded in the actual repo, not
  generic platitudes.
TASK

# --- copy .gitignore from source repo ---
if [[ -f "$ROOT/.gitignore" ]]; then
  cp "$ROOT/.gitignore" "$WORKTREE/.gitignore"
fi

# --- ignore state/ in worktree ---
WORKTREE_GITIGNORE="$WORKTREE/.gitignore"
if [[ ! -f "$WORKTREE_GITIGNORE" ]] || ! grep -qxF "state/" "$WORKTREE_GITIGNORE"; then
  printf "\nstate/\n" >> "$WORKTREE_GITIGNORE"
fi
if ! grep -qxF "FACTORY.md" "$WORKTREE_GITIGNORE"; then
  printf "FACTORY.md\n" >> "$WORKTREE_GITIGNORE"
fi

# --- install post-commit hook for worktree ---
cat > "$WORKTREE/hooks/post-commit" <<'HOOK'
#!/usr/bin/env bash
echo -e "\033[33mfactory:\033[0m NEW COMMIT"
HOOK
chmod +x "$WORKTREE/hooks/post-commit"
git -C "$WORKTREE" config core.hooksPath hooks

# --- copy original installer into worktree and commit ---
cp "$0" "$WORKTREE/factory.sh"
TASK_FILE="$(ls "$WORKTREE/tasks/"*.md 2>/dev/null | head -1)"
TASK_NAME="$(basename "$TASK_FILE" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')"
(
  cd "$WORKTREE"
  git add -f .gitignore CLAUDE.md FACTORY.md "$PY_NAME" factory.sh hooks/
  git commit -m "Bootstrap factory" >/dev/null 2>&1 || true
  git add -f tasks/
  git commit -m "New Task: $TASK_NAME" >/dev/null 2>&1 || true
)

# --- init ---
(
  cd "$WORKTREE"
  FACTORY_BRANCH="$BRANCH" python3 "$PY_NAME" init
) || { echo -e "\033[33mfactory:\033[0m init failed — aborting"; git worktree remove --force "$WORKTREE" 2>/dev/null || true; exit 1; }

# --- replace this installer with a launcher script (skip in dev mode) ---
if [[ "$DEV_MODE" == true ]]; then
  echo -e "\033[33mfactory:\033[0m dev mode — worktree at .git-factory/worktree"
  cd "$WORKTREE"
  FACTORY_BRANCH="$BRANCH" exec python3 "$PY_NAME"
fi

SCRIPT_PATH="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$0")"
LAUNCHER="$ROOT/factory"
if [[ "$SCRIPT_PATH" == "$ROOT"* ]] && [[ "$SCRIPT_PATH" != "$LAUNCHER" ]]; then
  rm -f "$SCRIPT_PATH" || true
fi
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
REPO="$(basename "$ROOT")"
BRANCH="factory/$REPO"
FACTORY_DIR="${ROOT}/.git-factory"
WORKTREE="${FACTORY_DIR}/worktree"
PY_NAME="factory.py"

if [[ "${1:-}" == "destroy" ]]; then
  echo "This will permanently remove:"
  echo "  - .git-factory/ (worktree + state)"
  echo "  - factory branch"
  echo "  - ./factory launcher"
  echo ""
  printf "Type 'yes' to confirm: "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    echo -e "\033[33mfactory:\033[0m destroy cancelled"
    exit 1
  fi

  # restore factory.sh from the worktree commit before destroying
  if [[ -f "$WORKTREE/factory.sh" ]]; then
    cp "$WORKTREE/factory.sh" "$ROOT/factory.sh"
    echo -e "\033[33mfactory:\033[0m restored factory.sh"
  fi

  # remove project worktrees under .git-factory/worktrees/
  if [[ -d "$FACTORY_DIR/worktrees" ]]; then
    for wt in "$FACTORY_DIR/worktrees"/*/; do
      [[ -d "$wt" ]] && git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    done
  fi

  # remove factory worktree then .git-factory dir
  if [[ -d "$WORKTREE" ]]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  fi
  rm -rf "$FACTORY_DIR"
  echo -e "\033[33mfactory:\033[0m removed .git-factory/"

  # delete all factory branches (factory/<repo> + project branches)
  git for-each-ref --format='%(refname:short)' 'refs/heads/factory/' | while read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
    echo -e "\033[33mfactory:\033[0m deleted '$b' branch"
  done

  # remove this launcher
  rm -f "$ROOT/factory"
  echo -e "\033[33mfactory:\033[0m destroyed"
  exit 0
fi

cd "$WORKTREE"
FACTORY_BRANCH="$BRANCH" exec python3 "$PY_NAME"
LAUNCH
chmod +x "$LAUNCHER"

# --- ignore the launcher via .git/info/exclude ---
if ! grep -qxF "/factory" "$EXCLUDE_FILE"; then
  printf "\n/factory\n" >> "$EXCLUDE_FILE"
fi

echo -e "\033[33mfactory:\033[0m worktree at .git-factory/worktree"
echo -e "\033[33mfactory:\033[0m run ./factory to start"

# --- run in foreground so user sees output ---
cd "$WORKTREE"
FACTORY_BRANCH="$BRANCH" exec python3 "$PY_NAME"
