# CrossBuild Helper

CrossBuild Helper provides the process-execution side of Cross Build when the iOS app cannot spawn arbitrary compiler processes.

## Local jailbreak helper

Run on the jailbroken device:

```sh
python3 Tools/crossbuild-helper.py --host 127.0.0.1 --port 8765 --workspace /var/mobile/Documents
```

For authentication, set `CROSSBUILD_HELPER_TOKEN` or pass `--token`, then enter the same token in Cross Build Settings → App Configuration.

## Remote build host

Run on a Mac/Linux build host reachable from the device:

```sh
CROSSBUILD_HELPER_TOKEN='change-me' python3 Tools/crossbuild-helper.py \
  --host 0.0.0.0 --port 8765 --workspace /path/to/projects
```

Configure the host, port, remote workspace and token in Cross Build. Prefer HTTPS or a trusted private network when exposing the helper beyond localhost.

Protocol:
- `GET /v1/health`
- `POST /v1/execute`
- `POST /v1/session/reset` — clears a session's remembered working directory and environment

The helper constrains requested working directories to `--workspace` when supplied.

### Persistent sessions

Each `/v1/execute` call still runs as its own subprocess — there is no long-lived shell
process behind a session. When a request includes `sessionID`, the helper instead
remembers that session's **working directory and exported environment variables**
after the command finishes and applies them as the starting point for the next
request with the same `sessionID`. This is enough for a terminal-style UI to feel
continuous (`cd foo` on one line affects the next line, `export FOO=bar` persists),
but it does **not** preserve shell functions/aliases, job control, or any state held
by a long-running foreground process (e.g. a REPL or `tail -f`) — those only live for
the single command that started them. Use `/v1/session/reset` to clear a session's
remembered state (e.g. when the app's terminal panel is cleared).
