#!/usr/bin/env python3
import argparse, json, os, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    server_version = "CrossBuildHelper/1.0"

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
            return self._json(200, {"ready":True,"version":"1.0","capabilities":["execute","environment","working-directory"]})
        self._json(404, {"error":"not found"})

    def do_POST(self):
        if not self._authorized():
            return self._json(401, {"error":"unauthorized"})
        if self.path != "/v1/execute":
            return self._json(404, {"error":"not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            command = str(payload.get("command", "")).strip()
            if not command:
                return self._json(400, {"error":"empty command"})
            cwd = payload.get("workingDirectory") or self.server.workspace or os.getcwd()
            if self.server.workspace:
                root = os.path.realpath(self.server.workspace)
                target = os.path.realpath(cwd)
                if target != root and not target.startswith(root + os.sep):
                    return self._json(403, {"error":"working directory is outside configured workspace"})
            env = os.environ.copy()
            env.update({str(k):str(v) for k,v in (payload.get("environment") or {}).items()})
            started = time.monotonic()
            result = subprocess.run(command, cwd=cwd, env=env, shell=True, executable="/bin/sh",
                                    capture_output=True, text=True, timeout=self.server.command_timeout or None)
            self._json(200, {"exitCode":result.returncode,"stdout":result.stdout,"stderr":result.stderr,
                             "duration":time.monotonic()-started})
        except subprocess.TimeoutExpired as e:
            self._json(200, {"exitCode":124,"stdout":e.stdout or "","stderr":"Command timed out.","duration":self.server.command_timeout})
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
    print(f"CrossBuild Helper listening on {a.host}:{a.port}", flush=True)
    server.serve_forever()

if __name__=="__main__":
    main()
