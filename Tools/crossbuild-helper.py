#!/usr/bin/env python3
import argparse, json, os, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def resolve_shell(requested=""):
    candidates = [requested] if requested else []
    candidates += [os.environ.get("SHELL",""), "/var/jb/bin/zsh", "/var/jb/bin/bash", "/var/jb/bin/sh",
                   "/bin/zsh", "/bin/bash", "/bin/sh"]
    for shell in candidates:
        if shell and os.path.isfile(shell) and os.access(shell, os.X_OK):
            return shell
    return ""

class SessionStore:
    """Tracks per-sessionID working directory + exported environment overrides
    across requests. Each command still runs as its own subprocess (there is no
    live shell process to attach to), but a session remembers 'cd' and 'export'
    effects between calls so a terminal UI feels persistent. Real job control,
    shell functions/aliases, and in-process state (e.g. a running REPL) are not
    preserved -- only cwd and env survive between commands in the same session."""
    def __init__(self):
        self._lock = threading.Lock()
        self._sessions = {}

    def get(self, session_id):
        if not session_id:
            return None, {}
        with self._lock:
            state = self._sessions.get(session_id, {})
            return state.get("cwd"), dict(state.get("env", {}))

    def update(self, session_id, cwd, env):
        if not session_id:
            return
        with self._lock:
            self._sessions[session_id] = {"cwd": cwd, "env": env}

    def clear(self, session_id):
        with self._lock:
            self._sessions.pop(session_id, None)

# Marker appended after the user's command so we can recover the shell's final
# cwd and a snapshot of its exported environment, letting the next request in
# the same session resume from where this one left off.
_STATE_MARKER = "__CROSSBUILD_STATE__"

def _wrap_with_state_capture(command):
    return "%s\nprintf '\\n%s\\n%%s\\n' \"$PWD\"\nenv\n" % (command, _STATE_MARKER)

def _extract_state(stdout):
    marker_idx = stdout.rfind("\n" + _STATE_MARKER + "\n")
    if marker_idx == -1:
        return stdout, None, None
    visible = stdout[:marker_idx]
    rest = stdout[marker_idx + len(_STATE_MARKER) + 2:]
    lines = rest.split("\n")
    cwd = lines[0] if lines else None
    env = {}
    for line in lines[1:]:
        if "=" in line:
            k, _, v = line.partition("=")
            if k:
                env[k] = v
    return visible, cwd, env

class Handler(BaseHTTPRequestHandler):
    server_version = "CrossBuildHelper/1.2"

    def _authorized(self):
        token = self.server.token
        return not token or self.headers.get("Authorization", "") == "Bearer " + token

    def _json(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._authorized():
            return self._json(401, {"error":"unauthorized"})
        if self.path == "/v1/health":
            return self._json(200, {"ready":True,"version":"1.2",
                "capabilities":["execute","environment","working-directory","shell-selection",
                                 "command-timeout","persistent-session-cwd-env"],
                "shell":resolve_shell()})
        self._json(404, {"error":"not found"})

    def do_POST(self):
        if not self._authorized():
            return self._json(401, {"error":"unauthorized"})
        if self.path == "/v1/session/reset":
            return self._handle_session_reset()
        if self.path != "/v1/execute":
            return self._json(404, {"error":"not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            command = str(payload.get("command", "")).strip()
            if not command:
                return self._json(400, {"error":"empty command"})

            session_id = str(payload.get("sessionID") or "").strip()
            session_cwd, session_env = self.server.sessions.get(session_id)

            cwd = payload.get("workingDirectory") or session_cwd or self.server.workspace or os.getcwd()
            if self.server.workspace:
                root = os.path.realpath(self.server.workspace)
                target = os.path.realpath(cwd)
                if target != root and not target.startswith(root + os.sep):
                    return self._json(403, {"error":"working directory is outside configured workspace"})

            env = os.environ.copy()
            env.update(session_env)
            env.update({str(k):str(v) for k,v in (payload.get("environment") or {}).items()})

            requested_shell = str(payload.get("shell") or "").strip()
            shell = resolve_shell(requested_shell)
            if not shell:
                return self._json(500, {"error":"no executable shell found"})

            init_command = str(payload.get("initCommand") or "").strip()
            base_command = (init_command + "\n" + command) if init_command else command
            full_command = _wrap_with_state_capture(base_command) if session_id else base_command

            args = [shell]
            if payload.get("loginShell"):
                args.append("-l")
            if payload.get("interactiveShell"):
                args.append("-i")
            args += ["-c", full_command]

            timeout = int(payload.get("timeout") or 0) or self.server.command_timeout or None
            started = time.monotonic()
            result = subprocess.run(args, cwd=cwd, env=env, shell=False,
                                    capture_output=True, text=True, timeout=timeout)

            stdout = result.stdout
            if session_id:
                visible, new_cwd, new_env = _extract_state(stdout)
                stdout = visible
                if new_cwd:
                    self.server.sessions.update(session_id, new_cwd, new_env or {})

            self._json(200, {"exitCode":result.returncode,"stdout":stdout,"stderr":result.stderr,
                             "duration":time.monotonic()-started,"shell":shell,
                             "sessionID": session_id or None})
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            err = e.stderr.decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
            self._json(200, {"exitCode":124,"stdout":out,"stderr":err + "\nCommand timed out.","duration":0})
        except Exception as e:
            self._json(500, {"error":str(e)})

    def _handle_session_reset(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            session_id = str(payload.get("sessionID") or "").strip()
            if not session_id:
                return self._json(400, {"error":"sessionID required"})
            self.server.sessions.clear(session_id)
            self._json(200, {"ok": True})
        except Exception as e:
            self._json(500, {"error":str(e)})

    def log_message(self, fmt, *args):
        if self.server.verbose:
            super().log_message(fmt, *args)

def main():
    p=argparse.ArgumentParser(description="Cross Build execution helper")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--workspace", default="")
    p.add_argument("--token", default=os.environ.get("CROSSBUILD_HELPER_TOKEN",""))
    p.add_argument("--command-timeout", type=int, default=0)
    p.add_argument("--verbose", action="store_true")
    a=p.parse_args()
    server=ThreadingHTTPServer((a.host,a.port),Handler)
    server.token=a.token
    server.workspace=os.path.realpath(a.workspace) if a.workspace else ""
    server.command_timeout=a.command_timeout
    server.verbose=a.verbose
    server.sessions=SessionStore()
    print("CrossBuild Helper listening on %s:%s shell=%s" % (a.host,a.port,resolve_shell() or "none"), flush=True)
    server.serve_forever()

if __name__=="__main__":
    main()
