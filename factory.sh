#!/usr/bin/env bash
set -euo pipefail

# factory.sh: bootstrap installer for the factory.
# Creates .factory/, extracts the Python runner, and launches it.

# --- constants ---
NOISES="Clanging Bing-banging Grinding Ka-chunking Ratcheting Hammering Whirring Pressing Stamping Riveting Welding Bolting Torqueing Clatter-clanking Thudding Shearing Punching Forging Sparking Sizzling Honing Milling Buffing Tempering Ka-thunking"
ROOT="$(git rev-parse --show-toplevel)"
FACTORY_DIR="${ROOT}/.factory"
PROJECT_WORKTREES="${FACTORY_DIR}/worktrees"
PY_NAME="factory.py"
EXCLUDE_FILE="$ROOT/.git/info/exclude"

# --- detect provider ---
PROVIDER=""
case "${1:-}" in claude|codex) PROVIDER="$1"; shift ;; esac
if [[ -z "$PROVIDER" ]]; then
  for try in claude claude-code codex; do
    command -v "$try" >/dev/null 2>&1 && PROVIDER="$try" && break
  done
fi

# --- detect default branch ---
REMOTE_HEAD="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
DEFAULT_BRANCH=""
for _b in main master "$REMOTE_HEAD"; do
  [[ -n "$_b" ]] && git show-ref --verify --quiet "refs/heads/$_b" && DEFAULT_BRANCH="$_b" && break
done
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# --- check dependencies ---
[[ -n "$PROVIDER" ]] || { echo -e "\033[31mfactory:\033[0m error: no agent CLI found (tried: claude, claude-code, codex)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo -e "\033[31mfactory:\033[0m error: python3 is not installed." >&2; exit 1; }

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
  fi

  rm -rf "$FACTORY_DIR"

  git for-each-ref --format='%(refname:short)' 'refs/heads/factory/' | while read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
  done
  rm -f "$ROOT/factory"
}

# --- writer: python runner ---
write_runner() {
cat > "$1/$PY_NAME" <<'RUNNER'
#!/usr/bin/env python3
import os, sys, re, signal, time, shutil, subprocess, ast, json, threading, atexit
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TASKS_DIR = ROOT / "tasks"
AGENTS_DIR = ROOT / "agents"
INITIATIVES_DIR = ROOT / "initiatives"
PROJECTS_DIR = ROOT / "projects"
STATE_DIR = ROOT / "state"
# parent repo — ROOT is .factory/, so parent is one level up
PARENT_REPO = ROOT.parent
DEFAULT_TOOLS = "Read,Write,Edit,Bash,Glob,Grep"

# --- config (written once at bootstrap) ---
_config = None

def _load_config():
    global _config
    if _config is None:
        p = ROOT / "config.json"
        _config = json.loads(p.read_text()) if p.exists() else {}
    return _config

def _get_default_branch():
    return _load_config().get("default_branch", "main")

def project_slug(project_path):
    """Extract slug from projects/YYYY-MM-slug.md -> slug."""
    name = Path(project_path).stem  # YYYY-MM-slug
    return re.sub(r"^\d{4}-\d{2}-", "", name)

def project_branch_name(project_path):
    return f"factory/{project_slug(project_path)}"

def _get_project_worktrees_dir():
    val = _load_config().get("project_worktrees")
    return Path(val) if val else ROOT / "worktrees"

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
    epilogue_md = ROOT / "EPILOGUE.md"
    if not epilogue_md.exists():
        return ""
    return epilogue_md.read_text().replace("{project_dir}", str(project_dir))

_has_progress = False

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
    name = _load_config().get("provider")
    if name:
        path = shutil.which(name)
        if path:
            _cli_cache = (name, path)
            return _cli_cache
    log("no agent CLI found (check config.json)")
    return None

# --- helpers ---

def load_agent(name):
    """Load an agent definition from agents/{name}.md."""
    path = AGENTS_DIR / f"{name}.md"
    if not path.exists():
        return None
    text = path.read_text()
    if not text.startswith("---"):
        return {"name": name, "prompt": text, "tools": DEFAULT_TOOLS}
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {"name": name, "prompt": text, "tools": DEFAULT_TOOLS}
    _, fm, body = parts
    meta = {}
    for line in fm.strip().splitlines():
        key, _, val = line.partition(":")
        if key.strip():
            meta[key.strip()] = val.strip()
    return {
        "name": name,
        "prompt": body.strip(),
        "tools": meta.get("tools", DEFAULT_TOOLS),
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
    name = path.stem
    return {
        "name": name,
        "tools": meta.get("tools", DEFAULT_TOOLS),
        "status": meta.get("status", ""),
        "handler": meta.get("handler", ""),
        "author": meta.get("author", ""),
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

def _glob_matches(base, pat):
    glob_pat = pat.replace("YYYY-MM-DD", "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]").replace("YYYY", "[0-9][0-9][0-9][0-9]")
    if any(ch in glob_pat for ch in "*?[]"):
        return any(base.glob(glob_pat))
    return (base / pat).exists()

def check_one_condition(cond, target_dir=None):
    base = target_dir or ROOT
    if not cond or cond == "always":
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
    if func == "file_exists":
        return _glob_matches(base, args[0])
    elif func == "file_absent":
        return not _glob_matches(base, args[0])
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
    if not done:
        return False
    return all(check_one_condition(c, target_dir) for c in done)

def check_done_details(done, target_dir=None):
    if not done:
        return False, []
    results = [(c, check_one_condition(c, target_dir)) for c in done]
    return all(ok for _, ok in results), results

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

def _build_prompt(prompt, allowed_tools, agent):
    if not agent or not agent.get("prompt"):
        return prompt, allowed_tools
    return f"{agent['prompt']}\n\n---\n\n{prompt}", agent.get("tools") or allowed_tools

def run_codex(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cli_path=None, cwd=None, run_log=None):
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

        log(f"codex failed with exit code {proc.returncode}")
        _dump_debug("codex", [stderr_text] if stderr_text else [], stdout_garbage)
        return False, None

    log("codex failed for all configured models")
    _dump_debug("codex", [last_stderr.decode(errors="replace")] if last_stderr else [], [])
    return False, None


def run_claude(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cli_path=None, cli_name=None, cwd=None, run_log=None):
    cli_path = cli_path or shutil.which(cli_name or "claude")
    if not cli_path:
        log("claude CLI not found on PATH")
        return False, None
    work_dir = cwd or ROOT

    full_prompt, allowed_tools = _build_prompt(prompt, allowed_tools, agent)

    model_name = os.environ.get("FACTORY_CLAUDE_MODEL", "claude-haiku-4-5-20251001").strip()
    model_arg = ["--model", model_name]
    log(f"  → using: {cli_name or 'claude'} \033[2m({model_name})\033[0m")

    proc = subprocess.Popen(
        [cli_path, "--dangerously-skip-permissions", "-p", "--verbose",
         "--output-format", "stream-json",
         full_prompt, "--allowedTools", allowed_tools, *model_arg],
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
                        if detail:
                            _show_progress(f"\033[36m  → {lname}:\033[0m \033[2m{detail}\033[0m")
                        else:
                            _show_progress(f"\033[36m  → {lname}\033[0m")
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
            log(f"claude failed with exit code {exit_code}")
            _dump_debug("claude", stderr_output, stdout_garbage)
        return exit_code == 0, result
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        print()
        log("task stopped")
        return False, result


def format_result(result):
    """Format a result event dict into a short string like '130.2s, $0.3683'."""
    if not result:
        return ""
    parts = []
    dur = result.get("duration_ms")
    cost = result.get("cost_usd") or result.get("total_cost_usd")
    if dur:
        parts.append(f"{dur/1000:.1f}s")
    if cost:
        parts.append(f"${cost:.4f}")
    return f"({', '.join(parts)})" if parts else ""

def run_agent(prompt, allowed_tools=DEFAULT_TOOLS, agent=None, cwd=None, run_log=None):
    cli = get_agent_cli()
    if not cli:
        return False, None
    cli_name, cli_path = cli
    if cli_name == "codex":
        return run_codex(prompt, allowed_tools, agent, cli_path, cwd=cwd, run_log=run_log)
    return run_claude(prompt, allowed_tools, agent, cli_path, cli_name, cwd=cwd, run_log=run_log)

# --- task planning ---

def plan_next_task():
    planning_md = ROOT / "agents" / "PLANNER.md"
    if not planning_md.exists():
        log("agents/PLANNER.md not found")
        return False
    today = time.strftime("%Y-%m-%d")
    prompt = planning_md.read_text().replace("{today}", today)
    log("\033[33mplanner\033[0m started:")
    head_before = sh("git", "rev-parse", "HEAD")
    run_log = _open_run_log("planning")
    try:
        ok, result = run_agent(prompt, run_log=run_log)
    finally:
        run_log.close()
    if not ok:
        log("planning failed")
        return False
    try:
        # squash any agent commits back to pre-planning state
        head_after = sh("git", "rev-parse", "HEAD")
        if head_after != head_before:
            sh("git", "reset", "--soft", head_before)
        sh("git", "add", "-A")
        porcelain = sh("git", "status", "--porcelain")
        info = format_result(result)
        if not porcelain:
            log(f"planner finished (nothing to commit) \033[2m{info}\033[0m" if info else "planner finished (nothing to commit)")
            log("")
            return True
        counts = {"initiatives": 0, "projects": 0, "tasks": 0}
        for line in porcelain.splitlines():
            path = line[3:]
            for key in counts:
                if path.startswith(key + "/"):
                    counts[key] += 1
        parts = [f"{n} {k}" for k, n in counts.items() if n]
        msg = f"updated: {', '.join(parts)}" if parts else "updated"
        sh("git", "commit", "-m", msg)
        log(f"  → {msg} \033[2m{info}\033[0m" if info else f"  → {msg}")
    except subprocess.CalledProcessError:
        log(f"planner finished (nothing to commit) \033[2m{info}\033[0m" if info else "planner finished (nothing to commit)")
    log("")
    return True

def handle_failure(task, details):
    """Run the planner with failure analysis context."""
    failure_md = ROOT / "agents" / "FIXER.md"
    if not failure_md.exists():
        log("agents/FIXER.md not found — skipping failure review")
        return
    name = task["name"]
    log(f"\033[31mfailure\033[0m review: {name}")

    task_content = task["_path"].read_text()
    run_log_path = STATE_DIR / "last_run.jsonl"
    run_log_tail = ""
    if run_log_path.exists():
        lines = run_log_path.read_text().splitlines()
        run_log_tail = "\n".join(lines[-50:])

    condition_report = "\n".join(
        f"  {'✓' if ok else '✗'} {cond}" for cond, ok in (details or [])
    )

    task_rel = task["_path"].relative_to(ROOT)
    prompt = failure_md.read_text() + "\n\n"
    prompt += f"## Failed Task ({task_rel})\n\n```\n{task_content}\n```\n\n"
    prompt += f"## Condition Results\n\n{condition_report}\n\n"
    if run_log_tail:
        prompt += f"## Run Log (last 50 lines)\n\n```\n{run_log_tail}\n```\n"

    head_before = sh("git", "rev-parse", "HEAD")
    run_log = _open_run_log("failure-review")
    try:
        ok, result = run_agent(prompt, run_log=run_log)
    finally:
        run_log.close()
    if not ok:
        log("  failure review crashed")
        log("")
        return
    try:
        head_after = sh("git", "rev-parse", "HEAD")
        if head_after != head_before:
            sh("git", "reset", "--soft", head_before)
        sh("git", "add", "-A")
        porcelain = sh("git", "status", "--porcelain")
        info = format_result(result)
        if not porcelain:
            log(f"  no changes \033[2m{info}\033[0m" if info else "  no changes")
            log("")
            return
        counts = {"initiatives": 0, "projects": 0, "tasks": 0}
        for line in porcelain.splitlines():
            path = line[3:]
            for key in counts:
                if path.startswith(key + "/"):
                    counts[key] += 1
        parts = [f"{n} {k}" for k, n in counts.items() if n]
        msg = f"updated: {', '.join(parts)}" if parts else "updated"
        sh("git", "commit", "-m", msg)
        log(f"  → {msg} \033[2m{info}\033[0m" if info else f"  → {msg}")
    except subprocess.CalledProcessError:
        info = format_result(result)
        log(f"  no changes \033[2m{info}\033[0m" if info else "  no changes")
    log("")

# --- main loop ---

def run():
    cli = get_agent_cli()
    if not cli:
        return

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

    def commit_task(task, message, scoop=False, work_dir=None):
        """Commit task metadata on the factory branch.

        scoop=True:  best-effort stage any uncommitted agent work.
        work_dir:    project worktree (if set, only the task file is committed
                     on the factory branch, not the project worktree).
        """
        if scoop and (work_dir is None or work_dir == ROOT):
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
        log(f"\033[32mtask\033[0m started: {name}")

        # determine work directory: project worktree or factory worktree
        is_project_task = task["parent"].startswith("projects/")
        if is_project_task:
            work_dir = ensure_project_worktree(task["parent"])
        else:
            work_dir = ROOT

        update_task_meta(task, status="active", pid=str(os.getpid()))
        commit_task(task, f"Start Task: {name}")
        # build prompt: instruction body + context + verify (exclude done)
        prompt_parts = [task["prompt"]]
        for section in ("context", "verify"):
            if section in task["sections"]:
                prompt_parts.append(f"## {section.title()}\n\n{task['sections'][section]}")
        prompt = "\n\n".join(prompt_parts)

        # surface done conditions so the agent knows exact acceptance criteria
        if task["done"] and task["done"] != ["always"]:
            checklist = "\n".join(f"- `{c}`" for c in task["done"])
            prompt += f"\n\n## Acceptance Criteria\n\nYour work is verified by these exact conditions — file paths and names must match precisely:\n\n{checklist}"

        # append epilogue for project tasks
        if is_project_task:
            prompt += build_epilogue(task, work_dir)

        # Load agent if specified
        agent_def = None
        if task.get("handler"):
            agent_name = task["handler"].replace("agents/", "").replace(".md", "")
            agent_def = load_agent(agent_name)
            if agent_def:
                log(f"using agent: {agent_name}")

        # snapshot HEAD before agent runs
        head_before = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=work_dir, stderr=subprocess.STDOUT
        ).decode().strip()

        run_log = _open_run_log(name)
        try:
            ok, result = run_agent(prompt, allowed_tools=task["tools"], agent=agent_def, cwd=work_dir, run_log=run_log)
        finally:
            run_log.close()
        session_id = (result or {}).get("session_id")
        if session_id:
            update_task_meta(task, session=session_id)

        # check if agent made any commits
        head_after = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=work_dir, stderr=subprocess.STDOUT
        ).decode().strip()
        agent_committed = head_before != head_after

        if not ok:
            # reset work dir first, then update meta (so reset doesn't wipe the meta change)
            if is_project_task:
                try:
                    subprocess.check_output(["git", "checkout", "--", "."], cwd=work_dir, stderr=subprocess.STDOUT)
                    subprocess.check_output(["git", "clean", "-fd"], cwd=work_dir, stderr=subprocess.STDOUT)
                except Exception:
                    pass
            update_task_meta(task, status="stopped", stop_reason="failed")
            commit_task(task, f"Failed Task: {name}")
            info = format_result(result)
            log(f"  ✗ task crashed \033[2m{info}\033[0m" if info else "  ✗ task crashed")
            log(f"  → log: {STATE_DIR / 'last_run.jsonl'}")
            log("")
            return
        if not agent_committed:
            log("agent made no commits")
        # squash agent commits into the runner's commit (factory tasks only)
        if agent_committed and not is_project_task:
            subprocess.check_output(
                ["git", "reset", "--soft", head_before], cwd=work_dir, stderr=subprocess.STDOUT
            )
        passed, details = check_done_details(task["done"], target_dir=work_dir)
        commit_work_dir = work_dir if is_project_task else None
        if passed:
            update_task_meta(task, status="completed", commit=head_after)
            commit_task(task, f"Complete Task: {name}", scoop=True, work_dir=commit_work_dir)
            info = format_result(result)
            log(f"  ✓ conditions: passed \033[2m{info}\033[0m" if info else "  ✓ all conditions passed")
        else:
            update_task_meta(task, status="stopped", stop_reason="incomplete")
            commit_task(task, f"Incomplete Task: {name}", scoop=True, work_dir=commit_work_dir)
            info = format_result(result)
            log(f"  ✗ conditions: failed \033[2m{info}\033[0m" if info else "  ✗ conditions not met")
            if details:
                for cond, ok in details:
                    mark = "✓" if ok else "✗"
                    log(f"    {mark} {cond}")
            log(f"  → log: {STATE_DIR / 'last_run.jsonl'}")
            log(f"  → task: {task['_path'].relative_to(ROOT)}")
            log("")
            handle_failure(task, details)

if __name__ == "__main__":
    run()
RUNNER
chmod +x "$FACTORY_DIR/$PY_NAME"
}

# --- writer: CLAUDE.md ---
write_claude_md() {
local REPO="$(basename "$ROOT")"
cat > "$1/CLAUDE.md" <<CLAUDE
# Factory

Automated software factory for \`$REPO\`.

Source repo: \`$ROOT\`
Factory dir: \`$FACTORY_DIR\`

You are a coding agent operating inside \`.factory/\`, a standalone git repo that
tracks factory metadata (tasks, projects, initiatives, agents). This directory
is separate from the source repo.

Project-specific tasks for the source repo will have separate worktrees created
under \`worktrees/\` each with its own branch prefixed with \`factory/\` in the
source repo. This is where you will do the actual code changes related to the
source repo.

Do not modify any files outside of these worktrees.

When you complete tasks, your commits will be merged back to the source repo by the runner.

Read \`$ROOT/PURPOSE.md\` for the source repo's Purpose, Measures, and Tests —
these define what "better" means and guide all planning and work.

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

All work is organized in three flat folders. There is no folder nesting.
Relationships are defined by frontmatter fields.

- \`initiatives/\` — high-level goals (see \`INITIATIVES.md\`)
- \`projects/\` — scoped deliverables under an initiative (see \`PROJECTS.md\`)
- \`tasks/\` — atomic units of work under a project (see \`TASKS.md\`)

### Lifecycle (Uniform Everywhere)

All initiatives, projects, and tasks use the same lifecycle states:

- \`backlog\` — defined but not active
- \`active\` — currently in play
- \`suspended\` — intentionally paused
- \`completed\` — finished successfully
- \`stopped\` — ended and will not resume

There is no \`failed\` state.
Failure is represented as:

\`\`\`yaml
status: stopped
stop_reason: failed
\`\`\`

### Structural Relationships

- \`parent:\` links a task → project or project → initiative.
- \`previous:\` defines sequential dependency between tasks.
- No \`parent\` means the task is a **factory maintenance task**.

### Scarcity Invariants (Must Always Hold)

- Exactly **1 active initiative**
- At most **2 active projects**
- At most **3 active tasks**
- At most **1 active unparented (factory) task**

If these constraints are violated, fix them before creating new work.

### Read-Set Rule

When planning or selecting work, you may only read items with:

status ∈ (active, backlog, suspended)

Completed work lives in git history. It does not remain active context.
CLAUDE
}

# --- writer: INITIATIVES.md ---
write_initiatives_md() {
cat > "$1/INITIATIVES.md" <<'INITIATIVES'
# Initiatives

Initiatives are high-level goals that define **what** the factory is trying to
achieve. Each initiative is a markdown file in `initiatives/` named
`YYYY-slug.md`.

## Format

```markdown
---
status: backlog
author: planner
---

## Problem

What's wrong now. What friction, gap, or limitation exists in the codebase.
Ground this in what you observe — name files, modules, workflows, user pain.
Not "testing could be better" — what specifically is broken or missing.

## Outcome

What's true when this initiative succeeds. Describe the end state, not the
work. Connect to Existential or Strategic Purpose — which bullet does this
advance?

Not "we will add tests" — "developers can refactor core modules confidently
because every public interface has contract tests."

## Scope

What's in and what's out. Initiatives without boundaries expand forever.
List 2–4 things explicitly excluded.

## Measures

How you know it's working. Observable signals — commands you can run, metrics
you can check, behaviors you can demonstrate. Draw from Existential or
Strategic Measures in the source repo's PURPOSE.md. If you can't point to a specific measure,
the initiative isn't grounded.
```

All four sections are required. An initiative that can't fill them isn't ready
to be created.

## Frontmatter

- **status** — lifecycle state (backlog, active, suspended, completed, stopped)
- **author** — who created this initiative (`planner`, `fixer`, or a custom name)
INITIATIVES
}

# --- writer: PROJECTS.md ---
write_projects_md() {
cat > "$1/PROJECTS.md" <<'PROJECTS'
# Projects

Projects are scoped deliverables that advance an initiative. Each project is a
markdown file in `projects/` named `YYYY-MM-slug.md`.

## Format

```markdown
---
status: backlog
author: planner
parent: initiatives/YYYY-slug.md
---

How this project advances the parent initiative. What slice of the initiative's
problem space it addresses. Which Strategic or Tactical Purpose bullets it
serves. How it relates to sibling projects (if any).

## Deliverables

Specific artifacts that will exist when this project is done. Not goals —
things. Files, behaviors, capabilities, removed code. Each deliverable is a
noun phrase that either exists or doesn't.

## Acceptance

Testable criteria — one per deliverable. Each answers "how do I verify this
deliverable is done?" These map directly to task Done conditions and should
connect to Strategic or Tactical Measures.

## Scope

What this project covers and what it explicitly does not. If the initiative
has multiple projects, explain the boundary between this one and its siblings.
```

All sections are required. A project without concrete deliverables and testable
acceptance criteria isn't ready to be created.

## Frontmatter

- **status** — lifecycle state (backlog, active, suspended, completed, stopped)
- **author** — who created this project (`planner`, `fixer`, or a custom name)
- **parent** — initiative this project advances (example: `initiatives/2026-improve-testing.md`)
PROJECTS
}

# --- writer: TASKS.md ---
write_tasks_md() {
cat > "$1/TASKS.md" <<'TASKS'
# Tasks

Tasks are atomic units of work. Each task is a markdown file in `tasks/`
named `YYYY-MM-DD-slug.md`. The runner (`factory.py`) picks up tasks, runs
them one at a time, and checks their completion conditions.

## Format

```markdown
---
tools: Read,Write,Edit,Bash
author: planner
parent: projects/name.md
previous: YYYY-MM-DD-other-task.md
---

What to do. This is the prompt — the agent's instruction for this run.
Be specific and concrete. Name files, functions, and behaviors.

## Done

Completion conditions checked by the runner after the agent finishes.
One condition per line. All must pass. Supported conditions:

- `file_exists("path")` — file exists in the worktree
- `file_absent("path")` — file does not exist
- `file_contains("path", "text")` — file contains text
- `file_missing_text("path", "text")` — file missing or lacks text
- `command("cmd")` — shell command exits 0
- `always` — task never completes (recurring)

## Context

Why this task exists. What purpose or measure it serves.

## Verify

How the agent should check its own work before committing.
```

## Frontmatter

Author-set fields:

- **tools** — allowed tools (default: `Read,Write,Edit,Bash,Glob,Grep`)
- **author** — who created this task (e.g. `planner`, `fixer`, or another agent's name)
- **parent** — project this task advances (example: `projects/2026-01-auth-hardening.md`). Omit for factory maintenance tasks.
- **previous** — filename of a task that must complete first (dependency)

Runner-managed fields (set automatically, do not write these yourself):

- **status** — lifecycle state
- **stop_reason** — required if `status: stopped`
- **pid** — process ID of the runner
- **session** — Claude session ID
- **commit** — HEAD commit hash when the task completed

## Creating follow-up tasks

If your task creates follow-up tasks, set the `previous` field in the new
task's frontmatter to the filename of the current task so the runner knows
the dependency order.
TASKS
}

# --- writer: agents/PLANNER.md ---
write_planner_md() {
cat > "$1/PLANNER.md" <<'PLANNING'
# Planning

You are the factory's planning agent. You are invoked whenever there is no
ready task. Read `INITIATIVES.md`, `PROJECTS.md`, and `TASKS.md` for format
specs.

Your job is to **review progress** and **ensure work is ready**. Every time
you run, work through these steps in order.

# Before You Begin

Read `{source_repo}/PURPOSE.md` — the source repo's Purpose, Measures, and Tests.

The planning hierarchy maps to the source repo's purpose hierarchy:

- **Initiatives** address Existential and Strategic purpose — the big gaps.
- **Projects** deliver against Strategic and Tactical purpose — compounding work.
- **Tasks** execute Tactical purpose — specific, near-term changes.

Every initiative must trace to Purpose. Every project must advance an initiative.
Every task must deliver a project artifact. If you can't draw the line from a
piece of work back to Purpose, don't create it.

# Step 1: Assess

Read all active and backlog items across all three levels. For each active
item, ask:

- Is it still the highest-leverage work available?
- Is it making progress, or is it stuck?
- Has completed work changed what's most important?
- Are any backlog items now more urgent than active ones?

Prune: mark stale or superseded items as `stopped` with
`stop_reason: superseded`.

Ignore completed and stopped items unless investigating regressions.

**Failed tasks**: If any task has `stop_reason: failed` or was marked
incomplete, follow the failure analysis protocol in `agents/FIXER.md` before
proceeding to Step 2. Do not skip this — the system must learn from every
failure before creating new work.

# Step 2: Complete

Check whether finished work should cascade upward:

- If all tasks under a project are completed, mark the project `completed`.
- If all projects under an initiative are completed, mark the initiative
  `completed`.

# Step 3: Fill

Work top-down. Only create what is missing.

**Initiatives** — If no active initiative exists:
- Read Purpose (all three levels). Identify the highest-leverage gap between
  current state and Purpose.
- Write the Problem section by examining the actual codebase — run commands,
  read files, find concrete evidence.
- The Outcome must connect to a specific Existential or Strategic Purpose bullet.
- The Measures must draw from Existential or Strategic Measures in the source repo's PURPOSE.md.
- Create 1–3 backlog initiatives and activate exactly one, or promote a
  backlog initiative.

**Projects** — If the active initiative has no active project:
- Read the initiative's Problem and Outcome. Decompose into independent,
  shippable slices — each project should deliver value on its own, not
  depend on other projects completing first.
- Write Deliverables as noun phrases (files, behaviors, capabilities).
- Write Acceptance criteria that map to Done conditions the runner can check.
- Each project's deliverables should advance Strategic or Tactical Purpose.
- Acceptance criteria should connect to Strategic or Tactical Measures.
- Order projects by leverage — activate the one that unblocks the most.
- Create all the projects the initiative needs (as many as appropriate —
  could be 1, could be 12). Activate 1–2.

**Tasks** — If the active project has no ready tasks:
- Read the project's Deliverables and Acceptance. Each task produces one
  deliverable or a clear fraction of one.
- Task prompts must name specific files, functions, and behaviors.
- Done conditions must be strict and automatable.
- Done conditions should be verifiable against Tactical Measures where possible.
- Chain tasks with `previous` when order matters.
- Create all the tasks needed to complete the project. Activate exactly one.
- Today's date is {today}. Name task files `{today}-slug.md`. If creating
  multiple tasks for the same day, vary the slug.

# Step 4: Validate

Before finishing, confirm:

- Scarcity invariants hold (see below).
- At least one task is ready to run (active, unblocked, conditions unmet).
- If not, something went wrong — investigate and fix.
- Quality gate — for every active item, answer:
  - Can I trace it to a specific Purpose bullet at the right level?
    (Initiative → Existential/Strategic, Project → Strategic/Tactical, Task → Tactical)
  - Does it have concrete, testable success criteria?
  - Is it the highest-leverage thing at its level?
  - Would I be embarrassed if a senior engineer reviewed it?

# Anti-Patterns

Do NOT do these:

- **Vague initiatives**: "Improve code quality" — no problem statement, no
  measures. Every initiative needs a specific Problem grounded in the codebase.
- **Kitchen-sink projects**: project tries to do everything the initiative
  needs in one shot. Decompose into independent, shippable slices.
- **Aspirational deliverables**: "Better test coverage" is not a deliverable;
  "Unit tests for auth module (auth/*.test.ts)" is.
- **Untestable acceptance**: "Code is cleaner" — how do you check that?
  Acceptance criteria must map to Done conditions.
- **Busywork tasks**: tasks that produce change but don't advance a
  deliverable. Every task must trace back to a project artifact.
- **Over-planning**: creating 20 backlog tasks when 5 would cover the project.
  Plan enough to maintain flow, not to predict the future.
- **Copy-paste structure**: every initiative looks the same because you are
  pattern-matching instead of thinking. Each initiative addresses a different
  problem — the structure should reflect that.

# Scarcity Invariants

These must always hold:

- Exactly **1 active initiative**
- At most **2 active projects**
- At most **3 active tasks**
- At most **1 active unparented (factory) task**

Scarcity governs active items, not backlog. You may create as many backlog
items as needed.

# Task Creation Rules

When writing tasks:
- Atomic, completable in one session.
- Names specific files, functions, and behaviors.
- Produces observable change.
- Includes strict Done conditions.
- Advances the active project (or is an unparented factory task).
- Always include `author: planner` in the frontmatter.

Unparented tasks are factory maintenance tasks. At most one may be active
at any time.

Do NOT commit. The runner will commit your work.
PLANNING
sed -i '' "s|{source_repo}|$ROOT|g" "$1/PLANNER.md"
}

# --- writer: agents/FIXER.md ---
write_fixer_md() {
cat > "$1/FIXER.md" <<'FAILURE'
# Failure Analysis Protocol

When you encounter a stopped task with `stop_reason: failed` or
`stop_reason: incomplete`, follow this protocol **before** creating any new
work. A failure is evidence that a factory Measure is not being met and a
Test is missing or inadequate. Your job is to identify which ones and fix
the system.

Read `PURPOSE.md` before proceeding — every step below references
the factory's own Purpose, Measures, and Tests.

## Step 1: Observe

Gather the facts:

- Read the task file (its prompt, Done conditions, and Context).
- Read the run log (`logs/`). What did the agent actually do?
- Read the git diff of what the agent produced (if anything).
- Note the delta between what was asked and what was delivered.

## Step 2: Diagnose

Identify which factory Measure was violated.

Read the Measures in `PURPOSE.md`. The failure violated at least
one — find it. Then ask: which Test should have caught this before the
task ran (or while it ran), and why didn't it?

- If no relevant Test exists, that is the gap.
- If a Test exists but didn't catch the failure, the Test is inadequate.
- If a Test caught it but the system ignored the result, the runner or
  the instructions have a gap.

Classify the level:

- **Existential** — the factory cannot operate at all (runner crashes,
  bootstrap fails, agent cannot start).
- **Strategic** — the factory operates but systematically produces wrong
  results (prompt construction drops context, format specs are ambiguous,
  completion checks are weak).
- **Tactical** — a specific task failed due to a narrow gap (missing
  instruction, unclear constraint, edge case in a condition).

The level determines the prescription's scope.

## Step 3: Prescribe

Create a new task that closes the gap. The task must:

- Include `author: fixer` in the frontmatter.
- **Target a system file** — `factory.py`, `CLAUDE.md`, `agents/PLANNER.md`,
  `TASKS.md`, or another factory-internal file. It does NOT redo the
  failed work.
- **Strengthen the Measure or add the Test** — the fix must either make
  the violated Measure enforceable or add/fix the Test that should have
  caught the failure. Connect the fix to a specific bullet in
  `PURPOSE.md`.
- Include Done conditions that verify the system change, not the
  original deliverable.

The failed task stays stopped. Do not modify or reactivate it.

## Step 4: Retry

After the systemic fix task completes, create a **new** task for the
original work (or an adjusted version if the failure revealed that the
original task was itself flawed). The new task benefits from the system
improvement and should not hit the same failure mode.

## Anti-Patterns

- **Retrying without diagnosing**: reactivating or duplicating the failed
  task without changing anything. The same system will produce the same
  failure.
- **Symptomatic fixes**: "add a note to the task telling the agent to read
  the conditions." This puts the burden on the task author instead of on
  the system. If an agent can ignore an instruction, the system has no
  enforcement — fix the system.
- **Skipping observation**: jumping to a theory without reading the log
  and diff. You cannot diagnose what you haven't observed.
- **Unmeasured fixes**: creating a fix task that doesn't trace to a
  specific Measure or Test in `PURPOSE.md`. If you can't name the
  Measure, you haven't diagnosed the failure.
FAILURE
}

# --- writer: EPILOGUE.md ---
write_epilogue_md() {
cat > "$1/EPILOGUE.md" <<'EPILOGUE'

---

## Epilogue

You are working in a project worktree at `{project_dir}`.
Your code changes go here.

When you are done:
1. Stage and commit your code changes in this worktree (the current directory).
   Use a short, descriptive commit message.
2. Stop. The runner will handle bookkeeping.
EPILOGUE
}

# --- writer: bootstrap tasks ---
write_bootstrap_tasks() {
local TODAY="$(date +%Y-%m-%d)"
local FACTORY_TASK="$1/${TODAY}-define-factory-purpose.md"
local REPO_TASK="$1/${TODAY}-define-repo-purpose.md"

cat > "$FACTORY_TASK" <<'TASK'
---
tools: Read,Write,Edit,Bash
author: factory
---

Examine this repository. Read its key files to understand what this software
does, how it is structured, and where its friction is.

Create `PURPOSE.md` in this directory with three sections: **Purpose**,
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

**Strategic Purpose** (5-8 bullets) — Define what properties this codebase
must have to keep fulfilling its existential purpose over time. Each bullet
should connect a codebase quality to the real-world outcome it protects. Not
"reduce complexity in core paths" — "complexity in core paths makes it unsafe
to change behavior users depend on." Not "improve test coverage" — "untested
interfaces erode confidence in the changes that deliver [existential purpose]."
The question is always: why does this property matter for the people or problem
the software serves?

**Tactical Purpose** (5-10 bullets) — Define what specific friction in this
codebase currently undermines the existential or strategic purpose, and why it
matters now. Name real files, modules, or workflows. Each bullet should connect
observable friction to the purpose it harms. Not "simplify the config module" —
"the config module's indirection obscures what the system actually does,
undermining [strategic purpose bullet]." Not "reduce test flakiness" —
"flaky tests in X cause developers to ignore failures, eroding [strategic
purpose bullet]." The question is always: why does this specific area need
attention, traced back to purpose?

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

## Done

- `file_contains("PURPOSE.md", "# Purpose")`
- `file_contains("PURPOSE.md", "# Measures")`
- `file_contains("PURPOSE.md", "# Tests")`

## Verify

- Confirm `PURPOSE.md` contains Purpose, Measures, and Tests
  sections with Existential, Strategic, and Tactical subsections.
- Confirm each subsection has the right number of bullets (3-5 existential, 5-8 strategic, 5-10 tactical).
- Read the sections back and check they are grounded in the actual repo, not
  generic platitudes.
TASK

# Task 2: same template, different repo
cp "$FACTORY_TASK" "$REPO_TASK"
sed -i '' \
  -e '/^tools:/a\
previous: '"${TODAY}"'-define-factory-purpose.md' \
  -e "s|Examine this repository|Examine the source repository at \`$ROOT\`|" \
  -e "s|in this directory|in the source repo root (\`$ROOT/\`)|" \
  -e "s|file_contains(\"PURPOSE.md\"|file_contains(\"$ROOT/PURPOSE.md\"|" \
  -e "s|Confirm \`PURPOSE.md\`|Confirm \`$ROOT/PURPOSE.md\`|" \
  "$REPO_TASK"
}

# --- writer: ./factory launcher ---
write_launcher() {
local LAUNCHER="$1/factory"
local SCRIPT_PATH="$(realpath "$0")"
if [[ "$SCRIPT_PATH" == "$1"* ]] && [[ "$SCRIPT_PATH" != "$LAUNCHER" ]]; then
  rm -f "$SCRIPT_PATH" || true
fi
cat > "$LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
FACTORY_DIR="${ROOT}/.factory"
PY_NAME="factory.py"

if [[ "${1:-}" == "teardown" ]]; then
  echo "This will permanently remove:"
  echo "  - All factory worktrees"
  echo "  - All factory/* branches"
  echo "  - .factory/ (standalone factory repo)"
  echo "  - factory launcher"
  echo "  - PURPOSE.md"
  echo ""
  printf "Type 'yes' to confirm: "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    echo -e "\033[33mfactory:\033[0m teardown cancelled"
    exit 1
  fi

  # restore factory.sh before teardown
  if [[ -f "$FACTORY_DIR/factory.sh" ]]; then
    cp "$FACTORY_DIR/factory.sh" "$ROOT/factory.sh"
    echo -e "\033[33mfactory:\033[0m restored factory.sh"
  fi

  # remove project worktrees (source repo worktrees)
  if [[ -d "$FACTORY_DIR/worktrees" ]]; then
    printf "\033[33mfactory:\033[0m removing worktrees..."
    for wt in "$FACTORY_DIR/worktrees"/*/; do
      [[ -d "$wt" ]] && git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    done
    printf "\r\033[33mfactory:\033[0m removed worktrees   \n"
  fi

  rm -rf "$FACTORY_DIR"
  echo -e "\033[33mfactory:\033[0m removed .factory/"

  # delete factory/* project branches
  git for-each-ref --format='%(refname:short)' 'refs/heads/factory/' | while read -r b; do
    git branch -D "$b" >/dev/null 2>&1 || true
    echo -e "\033[33mfactory:\033[0m deleted '$b' branch"
  done

  # remove source repo PURPOSE.md
  rm -f "$ROOT/PURPOSE.md"

  # remove this launcher
  rm -f "$ROOT/factory"
  echo -e "\033[33mfactory:\033[0m teardown complete"
  exit 0
fi

cd "$FACTORY_DIR"
exec python3 "$PY_NAME"
LAUNCH
chmod +x "$LAUNCHER"
if ! grep -qxF "/factory" "$EXCLUDE_FILE" 2>/dev/null; then
  printf "\n/factory\n" >> "$EXCLUDE_FILE"
fi
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
ensure_excluded() {
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  if ! grep -qxF "/.factory/" "$EXCLUDE_FILE" 2>/dev/null; then
    printf "\n/.factory/\n" >> "$EXCLUDE_FILE"
  fi
}

# --- bootstrap: set up .factory/ from scratch ---
write_files() {
  local dir="$1"
  mkdir -p "$dir"
  for d in tasks hooks state agents initiatives projects logs worktrees; do
    mkdir -p "$dir/$d"
  done
  cp "$0" "$dir/factory.sh"
  printf '%s\n' state/ logs/ worktrees/ .DS_Store Thumbs.db desktop.ini > "$dir/.gitignore"
  printf '{"default_branch": "%s", "project_worktrees": "%s", "provider": "%s"}\n' "$DEFAULT_BRANCH" "$PROJECT_WORKTREES" "$PROVIDER" > "$dir/config.json"
  write_runner "$dir"
  write_claude_md "$dir"
  write_initiatives_md "$dir"
  write_projects_md "$dir"
  write_tasks_md "$dir"
  write_epilogue_md "$dir"
  write_planner_md "$dir/agents"
  write_fixer_md "$dir/agents"
  write_bootstrap_tasks "$dir/tasks"
  write_hook "$dir/hooks"
}

bootstrap() {
  write_files "$FACTORY_DIR"

  # git
  git init "$FACTORY_DIR" >/dev/null 2>&1
  git -C "$FACTORY_DIR" config core.hooksPath hooks
  local TASK_FILE="$(ls "$FACTORY_DIR/tasks/"*.md 2>/dev/null | head -1)"
  local TASK_NAME="$(basename "$TASK_FILE" .md)"
  (
    cd "$FACTORY_DIR"
    git add -A
    git reset tasks/ >/dev/null 2>&1 || true  # unstage the bootstrap task(s)
    git commit -m "Bootstrap factory" >/dev/null 2>&1 || true
    git add tasks/
    git commit -m "Initial task: $TASK_NAME" >/dev/null 2>&1 || true
  )

}

# --- handle commands ---
case "${1:-}" in
  reset)
    teardown
    echo -e "\033[33mfactory:\033[0m reset"
    exit 0
    ;;
  dump)
    DUMP_DIR="$(dirname "$0")/factory_dump"
    rm -rf "$DUMP_DIR"
    write_files "$DUMP_DIR"
    echo -e "\033[33mfactory:\033[0m dumped to $DUMP_DIR"
    exit 0
    ;;
  dev)
    [[ -d "$FACTORY_DIR" ]] && teardown
    ensure_excluded
    bootstrap
    echo -e "\033[33mfactory:\033[0m dev mode — factory at .factory/"
    cd "$FACTORY_DIR"
    exec python3 "$PY_NAME"
    ;;
    help|--help|-h)
      echo "usage: ./factory.sh "
      echo ""
      echo "commands:"
      echo "   [claude|codex]   bootstrap or resume with specified provider (default: $PROVIDER)"
      echo "   dump             write all factory files to ./factory_dump/"
      echo "   reset            tear down .factory/, worktrees, and factory/* branches"
      echo "   help             display this help message"
      exit 0
      ;;
  *)
    ensure_excluded
    # resume if already bootstrapped
    if [[ -d "$FACTORY_DIR" ]] && [[ -f "$FACTORY_DIR/$PY_NAME" ]]; then
      echo -e "\033[33mfactory:\033[0m resuming"
      cd "$FACTORY_DIR"
      exec python3 "$PY_NAME"
    fi
    bootstrap
    write_launcher "$ROOT"
    cd "$FACTORY_DIR"
    exec python3 "$PY_NAME"
    ;;
esac
