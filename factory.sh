#!/usr/bin/env bash
set -euo pipefail

# factory.sh: bootstrap installer for the factory.
# Creates .factory/, extracts the Python runner, and launches it.

# --- constants ---
SOURCE_DIR="$(git rev-parse --show-toplevel)"
FACTORY_DIR="${SOURCE_DIR}/.factory"
PROJECT_WORKTREES="${FACTORY_DIR}/worktrees"
PY_NAME="factory.py"
EXCLUDE_FILE="$SOURCE_DIR/.git/info/exclude"

# --- detect provider and options ---
PROVIDER=""
case "${1:-}" in claude|codex) PROVIDER="$1"; shift ;; esac
KEEP_SCRIPT=false
case "${1:-}" in --keep-script) KEEP_SCRIPT=true; shift ;; esac
if [[ -z "$PROVIDER" ]]; then
  for try in claude claude-code codex; do
    command -v "$try" >/dev/null 2>&1 && PROVIDER="$try" && break
  done
fi

# --- detect default branch ---
REMOTE_HEAD="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
DEFAULT_BRANCH=""
for _b in "$REMOTE_HEAD" main master; do
  [[ -n "$_b" ]] && git show-ref --verify --quiet "refs/heads/$_b" && DEFAULT_BRANCH="$_b" && break
done
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# --- check dependencies ---
[[ -n "$PROVIDER" ]] || { echo -e "\033[31mfactory:\033[0m error: no agent CLI found (tried: claude, claude-code, codex)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo -e "\033[31mfactory:\033[0m error: python3 is not installed." >&2; exit 1; }

# --- writer: library ---
write_python() {
cat > "$1/library.py" <<'LIBRARY'
import re, ast, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TASKS_DIR = ROOT / "tasks"
STATE_DIR = ROOT / "state"
PARENT_REPO = ROOT.parent
DEFAULT_TOOLS = "Read,Write,Edit,Bash,Glob,Grep"


def parse_frontmatter(text):
    """Split text into (meta_dict, body_string) or None if invalid."""
    if not text.startswith("---"):
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    _, fm, body = parts
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        if key.strip():
            meta[key.strip()] = val.strip()
    return meta, body


def _task_line(t):
    """Format one task as a list item with parent and stop_reason."""
    parts = [t["name"]]
    if t["parent"]:
        parts.append(f"(parent: {t['parent']})")
    if sr := t.get("stop_reason"):
        parts.append(f"[stop_reason: {sr}]")
    return "- " + " ".join(parts)


def active_items(dirname, heading):
    """Scan a directory for active items, return (markdown section, count)."""
    if not (d := ROOT / dirname).exists():
        return f"## {heading}\n\nNone active.\n", 0
    lines = [f"## {heading}", ""]
    count = 0
    for f in sorted(d.glob("*.md")):
        text = f.read_text()
        parsed = parse_frontmatter(text)
        if parsed and parsed[0].get("status") == "active":
            lines.extend([f"### {f.stem}", text, ""])
            count += 1
    if not count:
        return f"## {heading}\n\nNone active.\n", 0
    return "\n".join(lines), count


def summarize_queue(tasks):
    """Build a markdown summary of the task queue."""
    completed = [t for t in tasks if t["status"] == "completed"]
    stopped = [t for t in tasks if t["status"] == "stopped"]
    remaining = [t for t in tasks if t["status"] not in ("completed", "stopped")]
    lines = ["## Queue", ""]
    if not any([completed, stopped, remaining]):
        lines.append("Empty queue — first planning cycle.")
        lines.append("")
    else:
        if completed:
            lines.append(f"**Completed** ({len(completed)} tasks)")
            lines.append("")
        if stopped:
            lines.append("**Stopped**")
            lines.extend(_task_line(t) for t in stopped)
            lines.append("")
        if remaining:
            lines.append("**Remaining**")
            lines.extend(_task_line(t) for t in remaining)
            lines.append("")
    return "\n".join(lines)


def purpose_of(entity):
    """Return the relative path to the purpose file for an entity, or None if it doesn't exist."""
    path = ROOT / "purpose" / f"{entity}.md"
    return str(path.relative_to(ROOT)) if path.exists() else None


def triage(task, details, work_dir=None):
    """Collect failed task, condition results, log tail for the fixer."""
    task_content = task["_path"].read_text()
    task_rel = task["_path"].relative_to(ROOT)
    cond_report = "\n".join(
        f"  {'✓' if ok else '✗'} {cond}" for cond, ok in (details or []))
    body = f"## Failed Task ({task_rel})\n\n```\n{task_content}\n```\n\n"
    body += f"## Condition Results\n\n{cond_report}\n\n"
    if work_dir and Path(work_dir) != ROOT:
        body += f"## Worktree\n\n`{work_dir}`\n\n"
    rlp = STATE_DIR / "last_run.jsonl"
    if rlp.exists():
        run_log_tail = "\n".join(rlp.read_text().splitlines()[-50:])
        if run_log_tail:
            body += f"## Run Log (last 50 lines)\n\n```\n{run_log_tail}\n```\n"
    return body


# --- task parsing ---

def parse_task(path):
    """Parse a task markdown file into a dict with frontmatter fields, completion conditions from ## Done, and the body as prompt.
    Returns None if frontmatter is missing or malformed."""
    text = path.read_text()
    parsed = parse_frontmatter(text)
    if not parsed:
        return None
    meta, body = parsed
    done_lines = []
    in_done = False
    in_fence = False  # skip fenced blocks (triage embeds tasks in code fences)
    for line in body.split("\n"):
        if line.strip().startswith("```"):
            in_fence = not in_fence
        if in_fence:
            continue
        if re.match(r'^##\s+[Dd]one\s*$', line):
            in_done = True
            continue
        if in_done and re.match(r'^##\s+', line):
            in_done = False
        if in_done:
            stripped = line.strip().lstrip("- ")
            m = re.match(r'`([^`]+)`', stripped)
            if m:
                done_lines.append(m.group(1))
            elif stripped and re.match(r'(\w+)\(', stripped):
                done_lines.append(stripped)
            elif stripped == "never":
                done_lines.append("never")
    return {
        "name": path.stem,
        "tools": meta.get("tools", DEFAULT_TOOLS),
        "status": meta.get("status", ""),
        "handler": meta.get("handler", ""),
        "author": meta.get("author", ""),
        "parent": meta.get("parent", ""),
        "previous": meta.get("previous", ""),
        "stop_reason": meta.get("stop_reason", ""),
        "done": done_lines,
        "prompt": body.strip(),
        "_path": path,
    }


def load_tasks():
    """Load all tasks from tasks/ directory, sorted by filename."""
    if not TASKS_DIR.exists():
        return []
    return [t for f in sorted(TASKS_DIR.glob("*.md")) if (t := parse_task(f))]


def update_task_meta(task, **kwargs):
    """Update YAML frontmatter fields in a task file."""
    path = task["_path"]
    text = path.read_text()
    _, fm, body = text.split("---", 2)
    lines = fm.strip().splitlines()
    existing = {}
    for i, line in enumerate(lines):
        key, _, _ = line.partition(":")
        existing[key.strip()] = i
    for key, val in kwargs.items():
        if val is None:
            continue
        if key in existing:
            lines[existing[key]] = f"{key}: {val}"
        else:
            lines.append(f"{key}: {val}")
    path.write_text("---\n" + "\n".join(lines) + "\n---" + body)


def next_id(directory):
    """Return the next monotonic ID for a directory of NNNN-slug.md files."""
    nums = [int(m.group(1)) for f in directory.glob("*.md")
            if (m := re.match(r"^(\d+)-", f.name))]
    return (max(nums) + 1) if nums else 1


# --- completion checks ---

def _glob_matches(base, pat):
    if any(ch in pat for ch in "*?[]"):
        return any(base.glob(pat))
    return (base / pat).exists()


def check_one_condition(cond, target_dir=None):
    """Evaluate a single completion condition string."""
    base = target_dir or ROOT
    if not cond or cond == "never":
        return False
    m = re.match(r'(\w+)\((.+)\)$', cond)
    if not m:
        return False
    func, raw_args = m.group(1), m.group(2)
    try:
        if not raw_args.strip():
            args = []
        else:
            parsed = ast.literal_eval(f"({raw_args})")
            args = [parsed] if isinstance(parsed, str) else list(parsed)
    except (ValueError, SyntaxError):
        return False
    if func == "file_exists":
        return _glob_matches(base, args[0])
    elif func == "file_absent":
        return not _glob_matches(base, args[0])
    elif func == "file_contains":
        if any(ch in args[0] for ch in "*?[]"):
            return any(args[1] in f.read_text() for f in base.glob(args[0]))
        p = base / args[0]
        return p.exists() and args[1] in p.read_text()
    elif func == "file_missing_text":
        if any(ch in args[0] for ch in "*?[]"):
            return all(args[1] not in f.read_text() for f in base.glob(args[0]))
        p = base / args[0]
        return not p.exists() or args[1] not in p.read_text()
    elif func == "command":
        try:
            # Yes, I get that this is unsafe but the commands are written by the factory & its agents
            # We trust that output inherently and being unsafe allows for complex (read: actually useful) checks
            subprocess.run(args[0], shell=True, cwd=base, check=True, capture_output=True)
            return True
        except subprocess.CalledProcessError:
            return False
    return False


def check_done(done, target_dir=None):
    """Check if all completion conditions pass. No conditions = always done."""
    if not done:
        return True
    return all(check_one_condition(c, target_dir) for c in done)


def check_done_details(done, target_dir=None):
    """Check conditions and return (passed, [(cond, bool), ...])."""
    if not done:
        return True, []
    results = [(c, check_one_condition(c, target_dir)) for c in done]
    return all(ok for _, ok in results), results


def next_task(tasks=None):
    """Find the next eligible task to run."""
    if tasks is None:
        tasks = load_tasks()
    eligible = [t for t in tasks if t["status"] not in ("completed", "stopped")]
    done_map = {t["_path"].name: True for t in tasks if t["status"] == "completed"}
    done_map.update({t["_path"].name: (bool(t["done"]) and check_done(t["done"])) for t in eligible})
    for t in eligible:
        if done_map.get(t["_path"].name):
            continue
        prev = t.get("previous", "").removeprefix("tasks/")
        if prev and not prev.endswith(".md"):
            prev += ".md"
        if prev and not done_map.get(prev, False):
            continue
        return t
    return None


# --- project helpers ---

def project_slug(project_path):
    """Extract slug from projects/NNNN-slug.md -> slug."""
    return re.sub(r"^\d+-", "", Path(project_path).stem)


def project_branch_name(project_path):
    return f"factory/{project_slug(project_path)}"


def read_md(name):
    """Read a markdown file from ROOT, or return empty string if missing."""
    p = ROOT / name
    return p.read_text() if p.exists() else ""
LIBRARY
cat > "$1/$PY_NAME" <<'RUNNER'
#!/usr/bin/env python3
import os, sys, re, signal, time, shutil, subprocess, json, threading, atexit, random
from library import (
    ROOT, TASKS_DIR, STATE_DIR, PARENT_REPO, DEFAULT_TOOLS,
    parse_frontmatter, load_tasks, update_task_meta, next_id,
    check_done, check_done_details, next_task,
    project_slug, project_branch_name, read_md,
    active_items, summarize_queue, purpose_of, triage,
)

AGENTS_DIR = ROOT / "agents"
LOGS_DIR = ROOT / "logs"
NOISES = "Clanging Bing-banging Grinding Ka-chunking Ratcheting Hammering Whirring Pressing Stamping Riveting Welding Bolting Torqueing Clatter-clanking Thudding Shearing Punching Forging Sparking Sizzling Honing Milling Buffing Tempering Ka-thunking".split()

# --- config (written once at bootstrap) ---
_config = None

def _load_config():
    global _config
    if _config is None:
        p = ROOT / "config.json"
        _config = json.loads(p.read_text()) if p.exists() else {}
    return _config

def _provider_cli():
    """Resolve provider binary from config. Returns (name, path) or None."""
    name = _load_config().get("provider")
    if name:
        path = shutil.which(name)
        if path:
            return name, path
    log(f"\033[33m⚙ factory\033[0m shutting down")
    log(f"  ✗ \033[31mno provider CLI found (check config.json)\033[0m")
    return None

def ensure_project_worktree(project_path):
    """Create project branch and worktree if needed."""
    slug = project_slug(project_path)
    branch = project_branch_name(project_path)
    wt_dir = ROOT / "worktrees" / slug
    default_branch = _load_config().get("default_branch", "main")

    def _git(*args):
        return subprocess.check_output(
            ["git"] + list(args), cwd=PARENT_REPO, stderr=subprocess.STDOUT
        ).decode().strip()

    # ensure branch exists
    try:
        _git("show-ref", "--verify", "--quiet", f"refs/heads/{branch}")
    except subprocess.CalledProcessError:
        _git("branch", branch, default_branch)

    # if dir exists but isn't a registered worktree, nuke it
    if wt_dir.exists():
        wt_list = _git("worktree", "list", "--porcelain")
        if str(wt_dir.resolve()) not in wt_list:
            shutil.rmtree(wt_dir, ignore_errors=True)
            _git("worktree", "prune")

    # create worktree if needed
    if not wt_dir.exists():
        wt_dir.parent.mkdir(parents=True, exist_ok=True)
        _git("worktree", "add", str(wt_dir), branch)
        base_hash = _git("rev-parse", "--short", branch)
        log(f"\033[33m⚙ factory\033[0m created workstream")
        log(f"  → branch: \033[2m{branch}\033[0m\n  → worktree: \033[2m{slug}\033[0m\n  → base: \033[2m{default_branch}@{base_hash}\033[0m\n")

    return wt_dir

_has_progress = False
_run_log_file = None
_ansi_regex = re.compile(r"\033\[[0-9;]*m")
_total_cost = 0.0
_task_count = 0
_start_time = None

def _show_progress(line):
    global _has_progress
    sys.stdout.write("\r" + line + "\033[K")
    sys.stdout.flush()
    _has_progress = True

def log(msg):
    global _has_progress
    if _has_progress:
        sys.stdout.write("\r\033[K")
        sys.stdout.flush()
        _has_progress = False
    print(msg, flush=True)
    if _run_log_file:
        _run_log_file.write(_ansi_regex.sub("", msg) + "\n")
        _run_log_file.flush()

def sh(*cmd):
    return subprocess.check_output(cmd, cwd=ROOT, stderr=subprocess.STDOUT).decode().strip()

def _acquire_pid():
    """Write pid file, returning False if another instance is running."""
    pid_file = STATE_DIR / "factory.pid"
    if pid_file.exists():
        try:
            old_pid = int(pid_file.read_text().strip())
            os.kill(old_pid, 0)
            log(f"\033[33m⚙ factory\033[0m shutting down")
            log(f"  ✗ \033[31manother instance is running (pid {old_pid})\033[0m")
            return False
        except (ValueError, ProcessLookupError, PermissionError):
            pass  # stale pid file, safe to overwrite
    pid_file.write_text(str(os.getpid()) + "\n")
    return True

def _cleanup_pid():
    pid_file = STATE_DIR / "factory.pid"
    try:
        pid_file.unlink(missing_ok=True)
    except OSError:
        pass

def _log_summary():
    if _start_time is None:
        return
    elapsed = time.monotonic() - _start_time
    mins = int(elapsed // 60)
    secs = int(elapsed % 60)
    log(f"\033[33m⚙ factory closed\033[0m {_task_count} tasks, ${_total_cost:.2f}, {mins}m{secs:02d}s")

def _handle_signal(signum, frame):
    _cleanup_pid()
    log(f"\033[33m⚙ factory\033[0m shutting down")
    log(f"  ✗ \033[31mreceived signal {signum}, exiting\033[0m")
    _log_summary()
    raise SystemExit(128 + signum)

signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, _handle_signal)
atexit.register(_cleanup_pid)

# --- helpers ---

def load_agent(name):
    """Load an agent definition from agents/{name}.md."""
    path = AGENTS_DIR / f"{name.upper()}.md"
    if not path.exists():
        return None
    text = path.read_text()
    parsed = parse_frontmatter(text)
    if not parsed:
        return {"name": name, "prompt": text, "tools": DEFAULT_TOOLS}
    meta, body = parsed
    return {
        "name": name,
        "prompt": body.strip(),
        "tools": meta.get("tools", DEFAULT_TOOLS),
    }


def write_task(slug, body, handler=None, tools=None, previous=None):
    name = f"{str(next_id(TASKS_DIR)).zfill(4)}-{slug}"
    path = TASKS_DIR / f"{name}.md"
    fm = ["author: factory", f"tools: {tools or DEFAULT_TOOLS}", "status: backlog"]
    if handler:
        fm.append(f"handler: {handler}")
    if previous:
        fm.append(f"previous: {previous}")
    path.write_text("---\n" + "\n".join(fm) + "\n---\n\n" + body)
    sh("git", "add", str(path.relative_to(ROOT)))
    sh("git", "commit", "-m", f"New Task: {name}")
    return name


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
    f = open(STATE_DIR / "last_run.jsonl", "w")
    if task_name:
        f.write(json.dumps({"type": "_factory", "task": task_name, "time": time.ctime()}) + "\n")
    return f

def _dump_debug(label, stderr_lines, stdout_garbage):
    if stderr_lines:
        log(f"--- {label} stderr ---")
        for line in stderr_lines:
            print(line)
        log(f"--- end ---")
    if stdout_garbage:
        log(f"--- {label} stdout garbage ---")
        for line in stdout_garbage:
            print(line)
        log(f"--- end ---")

def run_codex(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cli_path=None, cwd=None, run_log=None):
    cli_path = cli_path or shutil.which("codex")
    if not cli_path:
        log(f"\033[33m⚙ factory\033[0m shutting down")
        log(f"  ✗ \033[31mcodex CLI not found on PATH\033[0m")
        return False, None
    work_dir = cwd or ROOT

    if agent and agent.get("prompt"):
        full_prompt = f"{agent['prompt']}\n\n---\n\n{prompt}"
        allowed_tools = agent.get("tools") or allowed_tools
    else:
        full_prompt = prompt

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
        log(f"  → using: codex \033[2m({model_name})\033[0m")
        proc = subprocess.Popen(
            [cli_path, "exec", "--model", model_name, "--sandbox", "workspace-write", "--json", full_prompt],
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

        def _handle_event(ev):
            etype = ev.get("type")
            item = ev.get("item") or {}
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
                    _show_progress(f"\033[36m  → run:\033[0m \033[2m{cmd}\033[0m")
                return
            if etype == "item.completed":
                cmd = item.get("command") or ""
                out = item.get("aggregated_output") or ""
                exit_code = item.get("exit_code")
                if cmd:
                    prefix = "\033[36m✓ run\033[0m" if exit_code == 0 else "\033[31m✗ run\033[0m"
                    suffix = "" if exit_code == 0 else f" (exit {exit_code})"
                    log(f"{prefix} \033[2m{cmd}\033[0m{suffix}")
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
                        ev = json.loads(text)
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

        log(f"codex \033[31mfailed\033[0m with exit code {proc.returncode}")
        _dump_debug("codex", [stderr_text] if stderr_text else [], stdout_garbage)
        return False, None

    log("codex \033[31mfailed\033[0m for all configured models")
    _dump_debug("codex", [last_stderr.decode(errors="replace")] if last_stderr else [], [])
    return False, None


def run_claude(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cli_path=None, cli_name=None, cwd=None, run_log=None):
    cli_path = cli_path or shutil.which(cli_name or "claude")
    if not cli_path:
        log(f"\033[33m⚙ factory\033[0m shutting down")
        log(f"  ✗ \033[31mclaude CLI not found on PATH\033[0m")
        return False, None
    work_dir = cwd or ROOT

    system_args = []
    if agent and agent.get("prompt"):
        system_args = ["--system-prompt", agent["prompt"]]
        allowed_tools = agent.get("tools") or allowed_tools

    model_name = os.environ.get("FACTORY_CLAUDE_MODEL", "claude-haiku-4-5-20251001").strip()
    max_turns = os.environ.get("FACTORY_MAX_TURNS", "32").strip()
    model_arg = ["--model", model_name]
    log(f"  → using: {cli_name or 'claude'} \033[2m({model_name})\033[0m")

    proc = subprocess.Popen(
        [cli_path, "--permission-mode", "bypassPermissions", "-p", "--verbose",
         "--output-format", "stream-json",
         "--max-turns", max_turns,
         "--allowedTools", allowed_tools, *system_args, *model_arg, "--", prompt],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=work_dir,
    )
    result = None
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
        nonlocal result
        for raw in iter(proc.stdout.readline, b""):
            raw = raw.strip()
            if not raw:
                continue
            if run_log:
                run_log.write(raw.decode(errors="replace") + "\n")
                run_log.flush()
            try:
                ev = json.loads(raw)
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
                            cmd = inp.get("command", "").splitlines()[0]
                            maxw = shutil.get_terminal_size((80, 24)).columns - 22
                            detail = cmd[:maxw] + ("…" if len(cmd) > maxw else "")
                        lname = name.lower()
                        _show_progress(f"\033[36m  → {lname}{': ' + detail if detail else ''}\033[0m")
            elif t == "result":
                result = ev
    reader = threading.Thread(target=read_stream, daemon=True)
    reader.start()
    start = time.monotonic()
    deadline = start + AGENT_TIMEOUT if AGENT_TIMEOUT else None
    try:
        while reader.is_alive() or stderr_reader.is_alive():
            if deadline and time.monotonic() >= deadline:
                _kill_proc(proc, f"exceeded {AGENT_TIMEOUT:.0f}s timeout")
                return False, result
            reader.join(timeout=0.5)
            stderr_reader.join(timeout=0.5)

        exit_code = proc.wait()
        if exit_code != 0:
            log(f"claude \033[31mfailed\033[0m with exit code {exit_code}")
            _dump_debug("claude", stderr_output, stdout_garbage)
        return exit_code == 0, result
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        print()
        log("task stopped")
        return False, result


def _format_result(result):
    """Format result with $/hr rate (needs runner state)."""
    if not result:
        return ""
    parts = []
    dur = result.get("duration_ms")
    cost = result.get("cost_usd") or result.get("total_cost_usd")
    if dur:
        parts.append(f"{dur/1000:.1f}s")
    if cost:
        parts.append(f"${cost:.4f}")
    if _start_time is not None and _total_cost > 0:
        hrs = (time.monotonic() - _start_time) / 3600
        if hrs > 0:
            parts.append(f"${_total_cost / hrs:.2f}/hr")
    return f"({', '.join(parts)})" if parts else ""

def run_agent(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cwd=None, run_log=None):
    cli = _provider_cli()
    if not cli:
        return False, None
    cli_name, cli_path = cli
    if cli_name == "codex":
        return run_codex(prompt, allowed_tools, agent, cli_path, cwd=cwd, run_log=run_log)
    return run_claude(prompt, allowed_tools, agent, cli_path, cli_name, cwd=cwd, run_log=run_log)

# --- main loop ---

def run():
    cli = _provider_cli()
    if not cli:
        return

    if not _acquire_pid():
        return

    global _run_log_file, _start_time, _total_cost, _task_count
    _start_time = time.monotonic()
    _total_cost = 0.0
    _task_count = 0

    LOGS_DIR.mkdir(exist_ok=True)
    log_path = LOGS_DIR / time.strftime("%Y-%m-%d_%H%M%S.log")
    _run_log_file = open(log_path, "w")
    atexit.register(lambda: _run_log_file.close() if _run_log_file and not _run_log_file.closed else None)

    log(f"\033[H\033[2J\033[33m⚙ factory\033[0m starting up")
    log(f"  → repo: \033[2m{PARENT_REPO}\033[0m\n  → logs: \033[2m{log_path}\033[0m\n  → tasks: \033[2m{TASKS_DIR} ({len(load_tasks())})\033[0m \n")

    # --- git helpers ---
    #
    # Two repos are in play:
    #   1. Factory repo (.factory/) — task metadata, initiatives, projects, agent defs
    #   2. Source repo worktrees (.factory/worktrees/<slug>) — actual code changes
    #
    # Factory tasks (thinker/planner/fixer) work in the factory repo.
    #   Agent commits are squashed so each task = one clean commit.
    #
    # Project tasks (developer) work in a worktree on a factory/* branch.
    #   Agent commits stay as-is. Only the task file is updated in the factory repo.

    def commit_factory(task, message, stage_all=False):
        """Commit in the factory repo. Always stages the task file.
        If stage_all, also stages everything else (for factory tasks where
        the agent created files like initiatives/, projects/, tasks/)."""
        if stage_all:
            try:
                if sh("git", "status", "--porcelain"):
                    sh("git", "add", "-A")
            except Exception:
                pass
        rel = task["_path"].relative_to(ROOT)
        sh("git", "add", str(rel))
        sh("git", "commit", "-m", message)

    def git_head(cwd):
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=cwd, stderr=subprocess.STDOUT
        ).decode().strip()

    def git_log_subjects(cwd, old, new):
        """Return commit subjects between old..new, or [] on error."""
        try:
            return subprocess.check_output(
                ["git", "log", "--format=%s", f"{old}..{new}"],
                cwd=cwd, stderr=subprocess.STDOUT
            ).decode().strip().splitlines()
        except subprocess.CalledProcessError:
            return []

    while True:
        task = next_task()
        if task is None:
            all_tasks = load_tasks()
            if any(t["status"] not in ("completed", "stopped")
                   and not (bool(t["done"]) and check_done(t["done"]))
                   for t in all_tasks):
                log(f"\033[33m⚙ factory\033[0m shutting down")
                log(f"  ✗ \033[31mtasks exist but are blocked on dependencies\033[0m")
                _log_summary()
                return
            has_purpose = purpose_of("repo") is not None
            prj_section, prj_active = active_items("projects", "Active Projects")

            if not has_purpose:
                task_name = f"understand-{PARENT_REPO.name}"
                prompt = f"Understand the purpose of the source repository `{PARENT_REPO}` and write it in `purpose/repo.md`"
                write_task(task_name, prompt, handler="thinker", tools="Read,Glob,Grep,Write")
            elif prj_active == 0:
                queue = summarize_queue(all_tasks)
                ini_section, _ = active_items("initiatives", "Active Initiatives")
                prompt = f"Read `purpose/repo.md`.\n\n{queue}\n{ini_section}\n"
                write_task("roadmap", prompt, handler="planner", tools="Read,Write,Edit,Glob,Grep")
            else:
                queue = summarize_queue(all_tasks)
                prompt = f"Read `purpose/repo.md`.\n\n{queue}\n{prj_section}\n"
                write_task("decompose", prompt, handler="tasker", tools="Read,Write,Edit,Glob,Grep")
            continue

        name = task["name"]
        is_project_task = task["parent"].startswith("projects/")
        work_dir = ensure_project_worktree(task["parent"]) if is_project_task else ROOT

        log(f"\033[32mtask\033[0m started: {name}")

        # mark active and commit "Start Task" in factory repo
        update_task_meta(task, status="active", pid=str(os.getpid()))
        commit_factory(task, f"Start Task: {name}")

        # build prompt
        prologue = read_md("PROLOGUE.md") or ""
        body = task["prompt"] or ""
        epilogue = read_md("EPILOGUE.md").replace("{project_dir}", str(work_dir)).replace("{source_repo}", str(PARENT_REPO)) if is_project_task else ""
        prompt = "\n\n".join(p for p in [prologue, body, epilogue] if p)

        agent_def = None
        if task.get("handler"):
            agent_name = task["handler"].replace("agents/", "").replace(".md", "")
            agent_def = load_agent(agent_name)
            if agent_def:
                log(f"  → agent: {agent_name}")

        # snapshot HEAD before agent runs (in whichever repo the agent works in)
        head_before = git_head(work_dir)

        # --- run agent ---
        run_log = _open_run_log(name)
        try:
            ok, result = run_agent(prompt, allowed_tools=task["tools"], agent=agent_def, cwd=work_dir, run_log=run_log)
        finally:
            run_log.close()

        # extract result metadata
        res = result or {}
        session_id = res.get("session_id")
        if session_id:
            update_task_meta(task, session=session_id)
        duration_ms = res.get("duration_ms")
        cost_usd = res.get("cost_usd") or res.get("total_cost_usd")
        if cost_usd:
            _total_cost += cost_usd
        duration = f"{duration_ms/1000:.1f}s" if duration_ms else None
        cost = f"${cost_usd:.4f}" if cost_usd else None

        head_after = git_head(work_dir)
        agent_committed = head_before != head_after

        # --- agent crashed ---
        if not ok:
            if is_project_task:
                # revert uncommitted changes in the worktree
                try:
                    subprocess.check_output(["git", "checkout", "--", "."], cwd=work_dir, stderr=subprocess.STDOUT)
                    subprocess.check_output(["git", "clean", "-fd"], cwd=work_dir, stderr=subprocess.STDOUT)
                except Exception:
                    pass
            update_task_meta(task, status="stopped", stop_reason="failed", duration=duration, cost=cost)
            commit_factory(task, f"Failed Task: {name}")
            info = _format_result(result)
            log(f"  ✗ task \033[31mcrashed\033[0m \033[2m{info}\033[0m" if info else "  ✗ task \033[31mcrashed\033[0m")
            log(f"  → log: {STATE_DIR / 'last_run.jsonl'}")
            log("")
            _task_count += 1
            _log_summary()
            return

        # --- agent succeeded ---

        # capture agent commit subjects (before potential squash)
        summary_lines = git_log_subjects(work_dir, head_before, head_after) if agent_committed else []

        # factory tasks: squash agent commits so the whole task is one commit
        if agent_committed and not is_project_task:
            subprocess.check_output(
                ["git", "reset", "--soft", head_before], cwd=work_dir, stderr=subprocess.STDOUT
            )

        # check completion conditions
        passed, details = check_done_details(task["done"], target_dir=work_dir)

        # update task metadata and commit in factory repo
        if passed:
            update_task_meta(task, status="completed", commit=head_after, duration=duration, cost=cost)
        else:
            update_task_meta(task, status="stopped", stop_reason="incomplete", duration=duration, cost=cost)
        label = "Complete" if passed else "Incomplete"
        commit_factory(task, f"{label} Task: {name}", stage_all=not is_project_task)

        # log result
        info = _format_result(result)
        if passed:
            log(f"  ✓ conditions: \033[32mpassed\033[0m \033[2m{info}\033[0m" if info else "  ✓ all conditions \033[32mpassed\033[0m")
        else:
            log(f"  ✗ conditions: \033[31mfailed\033[0m \033[2m{info}\033[0m" if info else "  ✗ conditions \033[31mnot met\033[0m")
            for cond, ok_cond in details:
                log(f"    {'✓' if ok_cond else '✗'} {cond}")
            log(f"  → log: {STATE_DIR / 'last_run.jsonl'}")
            log(f"  → task: {task['_path'].relative_to(ROOT)}")
        for line in summary_lines:
            log(f"    {line}")
        log("")
        _task_count += 1

        # route incomplete tasks to fixer (not for planner/tasker/fixer/thinker tasks)
        if not passed and task.get("handler") not in ("planner", "tasker", "fixer", "thinker"):
            write_task("fix-failure", triage(task, details, work_dir=work_dir),
                       handler="fixer",
                       tools="Read,Write,Edit,Glob,Grep,Bash")

if __name__ == "__main__":
    run()
RUNNER
chmod +x "$1/$PY_NAME"
}

# --- writer: PROLOGUE.md ---
write_prologue_md() {
local REPO="$(basename "$SOURCE_DIR")"
cat > "$1/PROLOGUE.md" <<PROLOGUE
You are an agent operating inside \`.factory/\`, a standalone git repo that tracks factory metadata for \`$REPO\`.

Source repo: \`$SOURCE_DIR\`
Factory repo: \`$FACTORY_DIR\`

All file paths in factory metadata (task conditions, references, etc.) are relative to the factory root (\`.factory/\`). **NEVER** prefix paths with \`.factory/\` — you are already inside it.

If your task has a \`## Done\` section, those are machine-evaluated conditions the runner checks after you finish. File paths and names must match precisely. Available conditions: \`file_exists("path")\`, \`file_absent("path")\`, \`file_contains("path", "text")\`, \`file_missing_text("path", "text")\`, \`command("cmd")\` (exit 0), \`never\` (recurring task).

When creating task files, **ALWAYS** get the next ID by running: \`python3 -c "from library import next_id; from pathlib import Path; print(next_id(Path('tasks')))"\`. Zero-pad to 4 digits (e.g. \`0013\`).
PROLOGUE
}

# --- writer: AGENTS.md ---
write_specs() {
cat > "$1/AGENTS.md" <<'AGENTS'
# AGENTS.md

An agent is a set of instructions given to the CLI alongside a task prompt. The task says what to do. The agent says how to think.

Agents live in `agents/`. Each agent is a markdown file with frontmatter and a body.

## File format

```markdown
tools: Read,Write,Edit,Glob,Grep
author: factory
---

[agent body]
```

**Frontmatter:**
- `tools` — what the agent is allowed to use. The task can override this.
- `author` — who created the agent.

**Body:** the agent prompt, structured as described below.

## Agent structure

Every agent follows this structure:

### Identity

One line. What this agent does. Not a persona, not a backstory. A capability.

- "You think about things."
- "You plan work."
- "You diagnose failures."

If you need a paragraph, you don't know what the agent does yet.

### Capabilities

What this agent can do. Tools, access, actions. An agent that doesn't know what it can do either asks unnecessary questions or tries things that fail.

State what's available, not how to use it. The method section covers how.

### Method

How the agent does its work. Steps, in order. This is procedure, not principles.

Each step should be concrete enough that you could tell whether the agent did it. "Examine the repo" is a step. "Be thorough" is not.

If the method has conditional branches, state them. If steps have dependencies, state the order.

### Halt Condition

When to stop. What "I can't do this" looks like. What to output instead of nothing.

Every agent must have a defined failure mode. An agent with no halt condition will generate plausible garbage rather than admitting it's stuck.

### Validation

Self-checks the agent applies to its own output before finishing. These should be thinking tools, not checklists.

Good: "If you can ask 'to what end?' and get a meaningful answer, you haven't reached purpose yet."
Bad: "Ensure all statements are purpose-oriented."

The difference: a thinking tool changes what the agent generates. A checklist gets ignored.

### Rules

Hard constraints. Bullets. Short. Things that override everything else.

Rules are what the agent must never do or must always do regardless of context. If it's situational, it belongs in Method.

## How agents read tasks

Every agent interprets tasks the same way. This protocol is the shared contract between task and agent.

### Reading order

1. **Done conditions first.** This is what success looks like. Read these before the prompt. You are working backward from the end state.
2. **Prompt.** This is what to do. Execute it fully. It is not optional, aspirational, or negotiable.
3. **Context.** This is why. Read it for orientation. Do not treat it as additional instructions.
4. **Verify.** This is your self-check. Apply these before committing.

### Execution rules

- **Do the prompt. All of it.** Partial completion is failure.
- **Do only the prompt.** Do not add work the prompt didn't ask for. Do not improve adjacent code. Do not refactor while you're here. Scope is the prompt and nothing else.
- **Work backward from Done.** The done conditions define success. If your work doesn't satisfy them, you're not done. If you're unsure what the prompt means, the done conditions disambiguate.
- **Commit when done.** Stage your changes. Write a commit message that describes what changed, not the task name. Stop.
- **Halt if stuck.** If you cannot complete the prompt, stop. Do not produce partial work and hope. Do not silently skip parts. State what you attempted, what blocked you, and stop.

### What agents must never do

- Modify the task file. The runner manages task status and metadata.
- Start the next task. You do one task. The loop handles sequencing.
- Interpret Context as instruction. Context explains why, not what.
- Exceed the prompt scope. Adjacent improvements are future tasks, not bonus work.

## Principles

- **An agent is a method, not a persona.** Don't describe character, temperament, or attitude. Describe how it works.
- **The task carries the what. The agent carries the how.** If you're putting specific instructions about a particular job in the agent, it belongs in the task prompt. If you're putting method into a task prompt, it belongs in the agent.
- **Capabilities are separate from method.** What you can do vs how you do it. An agent might have Write access but only use it at the end. Capabilities state the former, method states the latter.
- **Halt conditions are not optional.** An agent that can't say "I'm stuck" will never be stuck — it'll just be wrong.
- **Validation catches the agent's own failure modes.** Write validation for the mistakes this specific agent is likely to make, not generic quality checks.
- **Interpretation is uniform.** Every agent reads tasks the same way. Done first, prompt second, context for orientation, verify before commit. No exceptions.
AGENTS
cat > "$1/INITIATIVES.md" <<'INITIATIVES'
# Initiatives

An initiative is a high-level goal that defines **what** the factory is trying to achieve. Each initiative is a markdown file in `initiatives/` named `NNNN-slug.md` (monotonic counter, e.g. `0001-slug.md`).

## File format

```markdown
---
author: planner
status: backlog
---

Very briefly re-interpret the **purpose** and outline an initiative that advances the codebase along some **measure** by focusing on some **part** or **principle**.

## Problem

## Outcome

## Scope

## Measures
```

## Initiative structure

**Frontmatter (all planner-set):**
- `status` — lifecycle state (`backlog`, `active`, `suspended`, `completed`, `stopped`). Add `stop_reason` when setting `stopped`.
- `author` — who created this initiative (`planner`, `fixer`, or a custom name).

### Intro paragraph (the text before any `##` section)

How this initiative connects to the purpose. Orientation for every downstream agent.

- Restate the purpose in one sentence (the concise bolded statement from `purpose/repo.md`).
- Name the specific measure this initiative advances.
- Explain how closing this gap moves that measure.

The purpose file is the canonical source of measures. The initiative's job is to connect to a measure, not redefine one.

### Problem

What friction, gap, or limitation exists in the codebase right now.

- Ground it in what you observe — name files, modules, workflows, user pain.
- Not "testing could be better" — what specifically is broken or missing.
- The problem must be evident from the source repo's current state. If you can't point to concrete evidence, you don't have a problem yet.

### Outcome

What is true when this initiative succeeds. The end state, not the work.

- Not "we will add tests" — "developers can refactor core modules confidently because every public interface has contract tests."
- One initiative, one outcome. If the outcome has "and" in it, you may have two initiatives.

### Scope

What is in and what is out. Initiatives without boundaries expand forever.

- List 2–4 things explicitly excluded.
- Scope defines where projects will operate. If you can't draw a boundary, the initiative is too vague.

### Measures

How you know the initiative is making progress. Break the outcome into parts that can each be independently observed.

- Not the purpose measures themselves — the initiative-level signals that show this specific gap is closing.
- If the outcome is "the system is fast," the measures might be "API responses under 200ms" and "page loads under 1s."
- If you can't break the outcome into observable parts, the initiative isn't concrete enough.

## What doesn't belong in an initiative

- **Solutions.** An initiative names the problem and the desired end state. It does not prescribe how to get there. That's what projects are for.
- **Vague problems.** "Code quality could be better" is not a problem. Name the specific gap with evidence from the source repo.
- **Disconnected outcomes.** If the intro paragraph can't name a specific measure from the purpose file, the initiative isn't grounded.
- **Unmeasurable outcomes.** If you cannot break the outcome into observable parts in the Measures section, the outcome is aspirational, not real.
- **Work that is really a project.** If the problem can be solved by one scoped deliverable, it's a project under an existing initiative, not a new initiative.
- **Multiple problems.** One initiative, one problem. If the Problem section has two distinct threads, split them.

## Drafting test

Before creating an initiative, ask:

- Can I restate the purpose and name the measure this initiative advances?
- Can I state the problem in one sentence, grounded in evidence from the source repo?
- Can I state the outcome as an end state, not as work to be done?
- Does the intro paragraph explain how closing this gap moves the named measure?
- Can I break the outcome into independently observable parts?
- Is this too big to be a project but too specific to be the entire purpose?

If any answer is no, the initiative needs rework.

## Principles

- **An initiative is a problem, not a solution.** It names what is wrong and what "fixed" looks like. It never prescribes how.
- **Outcomes are end states, not activities.** "Add integration tests" is an activity. "Every API endpoint has a contract test that runs in CI" is an end state.
- **The intro paragraph grounds the initiative.** It names the purpose, the measure, and the connection. Without it, downstream work drifts.
- **Measures are the progress contract.** The planner checks measures to decide whether to mark an initiative completed. They break the outcome into observable parts.
- **Scope prevents drift.** Without explicit exclusions, every initiative becomes "make everything better." The exclusions matter as much as the inclusions.
- **One active initiative at a time.** Scarcity forces prioritization. If the current initiative isn't the most important thing, stop it and start one that is.
INITIATIVES
cat > "$1/PROJECTS.md" <<'PROJECTS'
# Projects

A project is a scoped deliverable that advances an initiative. Each project is a markdown file in `projects/` named `NNNN-slug.md` (monotonic counter, e.g. `0001-slug.md`).

## File format

```markdown
---
author: planner
status: backlog
parent: initiatives/NNNN-slug.md
---

How this project advances the parent initiative.

## Deliverables

## Acceptance

## Scope
```

## Project structure

**Frontmatter (all planner-set):**
- `status` — lifecycle state (`backlog`, `active`, `suspended`, `completed`, `stopped`). Add `stop_reason` when setting `stopped`.
- `author` — who created this project (`planner`, `fixer`, or a custom name).
- `parent` — initiative this project advances (e.g., `initiatives/0001-improve-testing.md`).

### Intro paragraph (the text before any `##` section)

How this project advances the parent initiative. Orientation for the agent creating tasks.

- What slice of the initiative's problem space it addresses.
- Which constituent part from the purpose file it addresses and what purpose it serves.
- How it relates to sibling parts or projects, if any exist.

### Deliverables

Specific artifacts that will exist when this project is done. Not goals — things.

- Files, behaviors, capabilities, removed code.
- Each deliverable is a noun phrase that either exists or doesn't. "Unit tests for auth module (`auth/*.test.ts`)" is a deliverable. "Better test coverage" is a wish.
- Deliverables map 1:1 to tasks. If a deliverable needs more than one task, break the deliverable down further.

### Acceptance

Testable criteria, one per deliverable. Each answers "how do I verify this deliverable is done?"

- Must map to automatable Done conditions (the same condition types tasks use: `file_exists`, `file_contains`, `command`, etc.).
- No human judgment. "Code is cleaner" is not checkable. "Linter passes with zero warnings" is.
- Connect to Measures from the purpose file.

### Scope

What this project covers and what it explicitly does not.

- If the initiative has multiple projects, explain the boundary between this one and its siblings.
- Scope is smaller than the parent initiative's scope. If it's the same size, you only need one project.

## What doesn't belong in a project

- **Goals instead of deliverables.** "Improve performance" is a goal. "Response time for `/api/users` under 200ms" is a deliverable with a testable acceptance criterion.
- **Acceptance that requires human judgment.** "Code is well-structured" cannot be checked by the runner. Rephrase as something automatable.
- **Scope identical to the initiative.** If the project covers everything the initiative covers, either the initiative is too small (it should be a project) or the project needs to be decomposed.
- **Deliverables from a different initiative.** Every deliverable must advance the parent. If a deliverable traces to a different initiative, it belongs in a different project.
- **Implementation details.** A project says what will exist, not how it will be built. The tasks carry the how.

## Drafting test

Before creating a project, ask:

- Does every deliverable name a concrete artifact (file, behavior, capability)?
- Does every acceptance criterion map to an automatable Done condition?
- Can I trace every deliverable to the parent initiative's Problem or Outcome?
- Is the scope strictly smaller than the parent initiative's scope?
- Could this project ship independently of sibling projects?

If any answer is no, the project needs rework.

## Principles

- **A project is a deliverable, not a goal.** It names what will exist when the work is done. The things are specific enough that tasks can produce them.
- **Acceptance criteria are automatable.** Every criterion must be expressible as a Done condition the runner can check. If you can't write the condition, the criterion is too vague.
- **Projects are independent slices.** Each project delivers value on its own. If project B only makes sense after project A ships, they may be one project with sequenced tasks, not two projects.
- **Scope is the boundary between siblings.** When an initiative has multiple projects, the scope sections collectively partition the initiative's problem space. Gaps and overlaps are both failures.
- **Deliverables map to tasks.** If you can't see how a deliverable becomes 1–3 tasks with concrete Done conditions, the deliverable is too abstract. Break it down before creating the project.
- **At most two active projects at a time.** Scarcity forces focus. If a project is stalled or superseded, stop it before starting another.
PROJECTS
cat > "$1/TASKS.md" <<'TASKS'
# TASKS.md

A task is an atomic unit of work. It is the prompt given to an agent. The runner (`factory.py`) picks up tasks, runs them one at a time, and checks their completion conditions.

Tasks live in `tasks/`. Each task is a markdown file named `NNNN-slug.md` (monotonic counter, e.g. `0000-slug.md`).

## File format

```markdown
---
key: value - frontmatter key-value pairs go here
---

[Prompt body]

## Context

## Verify

## Done
```

## Task structure

**Frontmatter (author-set):**
- `tools` — allowed tools (default: `Read,Write,Edit,Bash,Glob,Grep`). Overrides the agent's tools if set.
- `author` — who created this task (`planner`, `fixer`, `factory`, or a custom name).
- `handler` — which agent runs this task (`developer`, `thinker`, `planner`, `tasker`, `fixer`). Use `developer` for source repo changes. Use `tasker` for decomposing projects into tasks.
- `parent` — project this task advances (e.g. `projects/0001-auth-hardening.md`). Omit for factory maintenance tasks.
- `previous` — task that must complete first (e.g. `tasks/0003-other-task.md`).

**Frontmatter (runner-managed — do not set these):**
- `status` — lifecycle state
- `stop_reason` — required if `status: stopped`
- `pid` — process ID of the runner
- `session` — agent session ID
- `commit` — HEAD commit hash when the task completed

### Prompt body (the text before any `##` section)

What to do. This is the agent's mandate for this run.

- **One outcome.** A task describes a single thing that will be different when it's done. "Add rate limiting to the /auth endpoint" is one outcome. "Check which files exist and create tasks for the missing ones" is a program — break it up.
- **Concrete targets.** Name files, functions, behaviors, paths. Not "improve the config" — "move the database URL from `config.ts` to `env.ts`."
- **What, not how.** The prompt says what must change. The agent's definition covers how. Do not put procedure, method, or conditional logic in the prompt.
- **Completable in one session.** If an agent can't finish it in one run, the task is too big. Split it.

The prompt is a mandate. The agent must do what it says, fully, or halt.

### Context

Why this task exists. Orientation, not instruction.

- Trace to a purpose, a measure, or a parent project.
- The agent reads this to understand why the work matters.
- **Not additional instructions.** If you're putting procedural steps or extra requirements in Context, they belong in the prompt. Agents are trained to read Context for orientation, not to execute it.

### Verify

Self-checks the agent applies to its own work before committing.

- "Read back the output and confirm every statement passes the 'to what end?' test."
- "Run the test suite and confirm no regressions."
- **Not additional work.** "Also update the README" is a second task or part of the prompt, not a verify step.

## What doesn't belong in a task

- **Method.** How to do the work. That's the agent's job.
- **Conditional logic.** "If X then do Y, otherwise do Z." That's two tasks, or the agent's judgment.
- **Self-modification.** "Edit this task's frontmatter." Tasks don't modify themselves. The runner manages status.
- **Sequencing.** "After this, create a task for..." Use `previous` for dependencies. If work needs to spawn follow-up tasks, that's a planner concern, not a task concern.
- **Vague outcomes.** "Improve," "clean up," "make better." These aren't outcomes. Name the specific thing that will be different.

## Drafting test

Before creating a task, ask:

- Can I state what's different when this is done in one sentence?
- Can I write the expected commit message in one line? If not, it's more than one task.
- Can I write done conditions that fully capture that sentence?
- Does the prompt contain only what, not how?
- Could any agent with the right capabilities complete this, not just one specific agent?

If any answer is no, the task needs rework.

## Principles

- **A task is one thing.** If it has conditional branches, it's multiple tasks. If it has sequencing logic, it's a plan. If it modifies itself, it's broken.
- **A task is one commit.** If you can't describe the change in a single commit message, the task is too broad. Split it.
- **Done conditions are the contract.** Not the prompt, not the context, not the verify section. The runner only checks done conditions. Everything else is for the agent.
- **The task carries the what. The agent carries the how.** Method, procedure, and technique do not belong in task prompts. If the prompt tells the agent how to do its work, the instructions belong in the agent definition instead.
- **Context is orientation, not instruction.** It explains why the work matters. Agents read it but do not execute it.
- **Scope is sacred.** A task does what the prompt says and nothing else. Adjacent improvements, refactors, and "while I'm here" fixes are future tasks.
- **At most three active tasks at a time; at most one active unparented (factory) task.** Scarcity keeps the queue shallow. Finish or stop tasks before adding more.

### Done

Completion conditions checked by the runner after the agent finishes. These are the contract — the only thing that determines success or failure.

Supported conditions (one per line, all must pass):
- `file_exists("path")` — file exists in the worktree
- `file_absent("path")` — file does not exist
- `file_contains("path", "text")` — file exists and contains text
- `file_missing_text("path", "text")` — file missing or lacks text
- `command("cmd")` — shell command exits 0
- `never` — task never completes (recurring)

Rules for done conditions:
- **Mechanically verifiable.** No human judgment. The runner checks these automatically.
- **Necessary and sufficient.** If the conditions pass, the task is done. If the task is done, the conditions pass. No gap in either direction.
- **Matched to the prompt.** If the prompt says "write X" and the done condition checks for Y, the task is broken.
- **Content, not formatting.** `file_contains` does exact substring matching. Never include markdown syntax (`#`, `**`, `-`) in the match text — agents vary heading levels and formatting. Match the words, not the decoration.
- **Paths are relative to the factory root.** You are inside `.factory/`. Use `tasks/0002-foo.md`, not `.factory/tasks/0002-foo.md`.
- **No redundant conditions.** `file_contains` implies `file_exists` — never use both on the same path.
- **Fewer is better.** 1–3 conditions for most tasks. If you need 10, you have 3 tasks.
TASKS
}

# --- writer: agents/ ---
write_agents() {
cat > "$1/THINKER.md" <<'THINKER'
---
tools: Read,Glob,Grep,Write
author: factory
---

You divine purpose. You are given an entity and a scope. Your primary operation: determine why it exists and how to measure whether it's fulfilling that purpose. You also identify its parts and principles — the parts tell the planner where to focus work, the principles tell the developer how to make decisions.

# Method

## 1. Examine the entity

Investigate through two lenses:

**Principles** — What makes this entity what it is and not something else? Its defining characteristics, cross-cutting conventions, architectural patterns, design constraints. These aren't parts — they're properties that span the whole. A principle applies everywhere; if it only applies to one part, it's a property of that part.

**Parts** — What are the logical constituents? The major subsystems, modules, domains. Distinguish **essential** (traces to entity's purpose) from **incidental** (traces to platform/toolchain). Focus on essential parts — these are where work happens.

## 2. Divine purpose

Why does this entity exist? What becomes true when it succeeds? If it were gone, what would break? Apply "to what end?" until you can't. Mechanism is not purpose.

## 3. Determine measures

How would you observe purpose being fulfilled *better or worse*? Measures define what "better" means. The planner uses them to find gaps. The fixer uses them to diagnose failures.

For each measure:
- It must track **degree**, not pass/fail. Prefer marginal over binary.
- It must include a **method of observation** — a command, metric, or concrete thing you can point at.
- It must connect to purpose.

## 4. Write purpose file

Write your output to `purpose/{scope}.md` where `{scope}` is the slug from your task (e.g. `purpose/repo.md`).

Structure the file as:

```

Why this entity exists or what it's for. Start with an extremely concise bolded statement: "The purpose of X is to...". Restate this in a new paragraph that includes what becomes true when it succeeds.

# Measures

How to observe purpose being fulfilled better or worse.  Each measure with its method of observation.

# Parts

The logical constituents — major subsystems, modules, domains.  Essential parts only. Each with a one-line description of what it does and how it relates to purpose.

# Principles

Cross-cutting conventions, architectural patterns, design constraints.  Each with enough context that a developer encountering a decision can check whether their choice is consistent.
```

The file should be readable on its own. No frontmatter, no YAML. Purpose and measures lead because they orient all downstream work. Parts follow because they tell the planner where to scope work. Principles last because they guide execution.

# Halt Condition

Before writing, answer internally:
- What becomes true when this succeeds?
- Who or what benefits, and what friction disappears?
- What capability becomes possible that didn't exist before?
- If this were gone tomorrow, what would break?

If you cannot answer at least three concretely, stop. Write the purpose file anyway, noting what you examined, what was ambiguous, and what needs a human answer.

# Rules

- No mission statements. No platitudes. No abstraction untethered from the entity.
- Purpose is the headline. Parts and principles serve it.
- Principles before parts. Understand what kind of thing it is before cataloging what it's made of.
- Essential before incidental.
- Prefer evidence to inference. Name the thing, not the category.
- Stop when done. Don't generate purpose you can't ground.
THINKER
cat > "$1/PLANNER.md" <<'PLANNER'
---
tools: Read,Write,Edit,Glob,Grep
author: factory
---

You own the roadmap. Your job is to decide: is the active initiative done? If not, what projects are still needed? If there is no active initiative, find the highest-leverage gap and create one.

You do not create tasks — the tasker handles that.

# Method

## 1. Read Purpose

Your task body begins with `Read purpose/repo.md …`. Read it first. It defines:

- **Purpose** — what the repo exists to do
- **Measures** — how you know it's working
- **Parts** — the subsystems and boundaries
- **Principles** — constraints and values

Everything you create must trace back to this file. If the purpose file is missing, halt — create nothing and explain what's missing.

## 2. Housekeeping

Review existing initiatives and projects. Mark stale or superseded items `stopped` with `stop_reason: superseded`.

## 3. Is the Active Initiative Done?

If there is an active initiative, read it. Read all projects under it and their statuses.

Check the initiative's outcome and measures against what the completed projects actually delivered.

- If **the outcome is met and the measures confirm it**: mark the initiative `completed`. Continue to step 4.
- If **work remains**: continue to step 5 to create projects for what is still missing.

If there is no active initiative, continue to step 4.

## 4. Create Initiatives

Read `specs/INITIATIVES.md`. Find the highest-leverage gap between the current state and the purpose. Before writing the Problem, write the intro paragraph: restating the purpose in one sentence, naming the measure this initiative advances and explaining how closing this gap moves that measure. Create 1–3 backlog initiatives. Activate exactly one. Continue to step 5.

## 5. Decompose into Projects

Read `specs/PROJECTS.md`. Take the active initiative and check what projects already exist. For each unmet part of the initiative's outcome, create a project. Do not recreate projects that already completed successfully.

Activate 1–2 projects.

## 6. Validate

Confirm at least one project is `active` and ready for the tasker. If not, investigate and fix.

# Rules

- Every initiative opens by restating the purpose and naming the measure it advances. Every project traces to an initiative.
- No vague initiatives. Name the specific gap, with evidence from the codebase.
- No aspirational deliverables. Name concrete artifacts.
- No untestable acceptance. Criteria must map to automatable Done conditions.
- No busywork. Every item must advance its parent toward a stated measure.
- No over-planning. Plan enough to maintain flow.
- Do not create tasks. That is the tasker's job.
PLANNER
cat > "$1/TASKER.md" <<'TASKER'
---
tools: Read,Write,Edit,Glob,Grep
author: factory
---

You own an active project. Your job is to decide: is this project done? If not, what still needs to be done?

# Method

## 1. Read Purpose

Your task body begins with `Read purpose/repo.md …`. Read it for context on measures and parts, but your primary input is the active project file.

## 2. Read the Project

Read the active project file in `projects/`. Understand its deliverables, acceptance criteria, and scope.

## 3. Review Completed Work

Read all tasks under this project (`parent: projects/NNNN-slug.md`). For each completed task, understand what it delivered. For stopped or failed tasks, understand what went wrong.

If this is the first run (no tasks exist yet), skip to step 4.

## 4. Is the Project Done?

Check every deliverable and acceptance criterion in the project file against what has actually been delivered.

- If **every deliverable is met and every acceptance criterion passes**: mark the project `completed` by editing its frontmatter to `status: completed`. You are done.
- If **work remains**: continue to step 5.

## 5. Create Tasks

Read `specs/TASKS.md`. For each unmet deliverable, create one task (or a small number if the deliverable requires sequencing). Each task:

- Produces one concrete artifact or change.
- Has `handler: developer` if it changes source repo code.
- Has `parent: projects/NNNN-slug.md` pointing to the active project.
- Has Done conditions that are mechanically verifiable.
- Uses `previous: tasks/NNNN-slug.md` for sequencing where one task depends on another.

Do not recreate tasks that already completed successfully. Only create tasks for what is still missing.

Activate exactly one task. The rest stay `backlog`.

## 6. Validate

Confirm the active task can run immediately — no unmet dependencies, no missing context. If not, investigate and fix.

# Rules

- Each task is one commit. If you can't describe it in a single commit message, split it.
- Done conditions are the contract. Match them to the prompt, not to aspirations.
- No method in prompts. Say what, not how. The developer carries the how.
- No busywork. Every task must deliver a project artifact.
- Do not create initiatives or projects. That is the planner's job.
TASKER
cat > "$1/FIXER.md" <<'FIXER'
---
tools: Read,Write,Edit,Glob,Grep,Bash
author: factory
---

You diagnose failures and fix the system that produced them. You do not redo the failed work. You do not modify or reactivate stopped tasks.

You are invoked when a task stops with `stop_reason: failed` or `stop_reason: incomplete`. Read the relevant purpose file in `purpose/` to orient on purpose and measures before proceeding.

# Method

## 1. Observe

Gather facts:

- Read the failed task file — its prompt, Done conditions, and Context.
- Read the run log (`state/last_run.jsonl`). What did the agent actually do?
- If a `## Worktree` section is present, the failed task ran in that worktree — inspect diffs and files there, not in the factory root.
- Read the git diff of what the agent produced, if anything.
- Note the delta between what was asked and what was delivered.

## 2. Diagnose

Identify what went wrong at the system level. Read the Measures from the relevant purpose file in `purpose/`. The failure violated at least one — find it. Then ask: what should have caught this before or during the task, and why didn't it?

- No relevant check exists → that's the gap.
- A check exists but missed the failure → the check is inadequate.
- A check caught it but the system ignored the result → the runner or instructions have a gap.

## 3. Prescribe

Create a new task that closes the gap:

- Include `author: fixer` in frontmatter.
- Target a factory-internal file — `factory.py`, `PROLOGUE.md`, an agent definition, a format spec.
- **Do not modify files in the worktree or source repo.** Only change factory-internal files.
- The fix must strengthen the violated measure or add the check that should have caught the failure.
- Done conditions verify the system change, not the original deliverable.

## 4. Retry

Create a new task for the original work — adjusted if the failure revealed the original task was flawed. The failed task stays stopped.

# Halt Condition

If the failure has no observable evidence — no run log, no diff, no agent output — state what's missing and stop.

If the failure cannot be traced to a system gap — the agent had clear instructions, correct tools, and adequate checks, and still failed — note that the failure may be non-systemic and stop.

# Rules

- Never retry without diagnosing. The same system produces the same failure.
- Never create symptomatic fixes. "Add a note telling the agent to be careful" is not a system fix.
- Never diagnose without observing. No log, no diagnosis.
- Every fix must trace to a specific measure from a purpose file.
- Never modify or reactivate the failed task. New work goes in new tasks.
FIXER
cat > "$1/DEVELOPER.md" <<'DEVELOPER'
---
tools: Read,Write,Edit,Glob,Grep,Bash
author: factory
---

You implement deliverables in a project worktree — a separate checkout on a branch off the default branch. Your current directory is the worktree. **Use only relative paths or paths within the current directory.** The worktree contains the full source tree.

# Method

## 1. Orient

Read the task body. Identify the deliverable, the Done conditions, and any Context section. Read existing code in the worktree (use relative paths) before writing anything.

## 2. Implement

Make the change. Stay in scope — implement what the task asks, nothing more. Follow existing conventions (naming, structure, style, test patterns).

## 3. Verify

If Done conditions include a `command()`, run it and confirm it passes. If they include `file_contains()` or `file_exists()`, confirm the files are correct. Fix failures before proceeding — the runner checks these conditions after you stop.

## 4. Commit

Stage and commit your changes with a short, descriptive message. The runner handles everything else.

# Rules

- **Use relative paths.** Your cwd is the worktree root. Read `www/package.json`, not `/absolute/path/to/repo/www/package.json`.
- Read before writing. Understand the code you're changing.
- One task, one concern. Don't refactor or improve adjacent code.
- Don't invent requirements. If the task doesn't ask for it, don't build it.
- Match existing style exactly.
- Every Done condition must pass before you stop. If one can't pass, explain why and stop without committing.
DEVELOPER
}

# --- writer: EPILOGUE.md ---
write_epilogue_md() {
cat > "$1/EPILOGUE.md" <<'EPILOGUE'

---

## Worktree

Your working directory is `{project_dir}`. This is a git worktree — a separate checkout on a project branch. **All reads and writes MUST use paths within this directory.**

Do not use paths under `{source_repo}`.  **EDITING FILES IN {source_repo} WILL CAUSE IRREPARABLE HARM**

When you are done, stage and commit your changes in this directory with a short message. The runner handles everything else.
EPILOGUE
}

# --- writer: ./factory launcher ---
write_launcher() {
cat > "$1/factory" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "teardown" ]]; then
  echo "This will permanently remove:"
  echo "  - The .factory/ itself (standalone repo)"
  echo "  - All factory worktrees & factory/* branches"
  echo "  - factory launcher"
  echo ""
  printf "Hit 'y' to confirm: "
  read -r confirm
  if [[ "\$confirm" != "y" ]]; then
    echo -e "\033[33m⚙ factory:\033[0m teardown cancelled"
    exit 1
  fi
  cp "$FACTORY_DIR/factory.sh" "$SOURCE_DIR/factory.sh"
  cd "$SOURCE_DIR"
  exec bash "$SOURCE_DIR/factory.sh" teardown
fi

cd "$FACTORY_DIR"
exec python3 "$PY_NAME"
LAUNCH
chmod +x "$SOURCE_DIR/factory"
}

# --- writer: post-commit hook ---
write_hook() {
cat > "$1/post-commit" <<'HOOK'
#!/usr/bin/env bash
echo -e "NEW COMMIT"
HOOK
chmod +x "$1/post-commit"
}

# --- ensure .factory/ is locally ignored ---
setup_excludes() {
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  if ! grep -qxF "/.factory/" "$EXCLUDE_FILE" 2>/dev/null; then
    printf "\n/.factory/\n" >> "$EXCLUDE_FILE"
  fi
  if ! grep -qxF "/factory" "$EXCLUDE_FILE" 2>/dev/null; then
    printf "\n/factory\n" >> "$EXCLUDE_FILE"
  fi
}

remove_script() {
  rm -f "$SOURCE_DIR/factory.sh"
}

# --- write all factory files to a directory ---
write_files() {
  local dir="$1"
  mkdir -p "$dir"
  for d in tasks hooks state agents initiatives projects logs worktrees specs purpose; do
    mkdir -p "$dir/$d"
  done
  cp "$0" "$dir/factory.sh"
  printf '%s\n' __pycache__/ state/ logs/ worktrees/ .DS_Store Thumbs.db desktop.ini > "$dir/.gitignore"
  printf '{\n"default_branch": "%s",\n"project_worktrees": "%s",\n"provider": "%s"\n}\n' "$DEFAULT_BRANCH" "$PROJECT_WORKTREES" "$PROVIDER" > "$dir/config.json"
  write_python "$dir"
  write_prologue_md "$dir"
  write_epilogue_md "$dir"
  write_specs "$dir/specs"
  write_agents "$dir/agents"
  write_hook "$dir/hooks"
}

setup_repo() {
  git init "$FACTORY_DIR" >/dev/null 2>&1
  git -C "$FACTORY_DIR" config core.hooksPath hooks
  (
    cd "$FACTORY_DIR"
    git add -A
    git commit -m "Bootstrap factory" >/dev/null 2>&1 || true
  )
}

# --- tear down .factory/, worktrees, and factory/* branches ---
teardown() {
  if [[ -z "$FACTORY_DIR" ]] || [[ "$FACTORY_DIR" != *".factory" ]]; then
    echo -e "\033[31mfactory:\033[0m error: unsafe FACTORY_DIR: $FACTORY_DIR" >&2
    exit 1
  fi

  if [[ -d "$FACTORY_DIR/worktrees" ]]; then
    for wt in "$FACTORY_DIR/worktrees"/*/; do
      [[ -d "$wt" ]] && git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    done
    git worktree prune 2>/dev/null || true
  fi

  rm -rf "$FACTORY_DIR"

  git for-each-ref --format='%(refname:short)' 'refs/heads/factory/' | while read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
  done
  rm -f "$SOURCE_DIR/factory"
}

# --- handle commands ---
bootstrap() {
  setup_excludes
  write_files "$FACTORY_DIR"
  setup_repo
  write_launcher "$SOURCE_DIR"
  [[ "$KEEP_SCRIPT" == true ]] || remove_script
}

# --- handle commands ---
case "${1:-}" in
  help|--help|-h)
    echo "usage: ./factory.sh "
    echo ""
    echo "commands:"
    echo "   [claude|codex]   bootstrap or resume with specified provider (default: $PROVIDER)"
    echo "   bootstrap        bootstrap .factory/ without launching the agent"
    echo "   dump             write all factory files to ./factory_dump/"
    echo "   teardown         tear down .factory/, worktrees, and factory/* branches"
    echo "   help             display this help message"
    exit 0
    ;;
  bootstrap)
    if [[ -d "$FACTORY_DIR" ]] && [[ -f "$FACTORY_DIR/$PY_NAME" ]]; then
      echo -e "\033[33m⚙ factory:\033[0m already bootstrapped"
      exit 0
    fi
    bootstrap
    echo -e "\033[33m⚙ factory:\033[0m bootstrap complete"
    exit 0
    ;;
  teardown)
    teardown
    echo -e "\033[33m⚙ factory:\033[0m teardown complete"
    exit 0
    ;;
  dump)
    DUMP_DIR="$(dirname "$0")/factory_dump"
    rm -rf "$DUMP_DIR"
    write_files "$DUMP_DIR"
    echo -e "\033[33m⚙ factory:\033[0m dumped to $DUMP_DIR"
    exit 0
    ;;
  *)
    # if bootstrapped, resume
    if [[ -d "$FACTORY_DIR" ]] && [[ -f "$FACTORY_DIR/$PY_NAME" ]]; then
      echo -e "\033[33m⚙ factory:\033[0m resuming"
      cd "$FACTORY_DIR"
      exec python3 "$PY_NAME"
    fi
    bootstrap
    cd "$FACTORY_DIR"
    exec python3 "$PY_NAME"
    ;;
esac
