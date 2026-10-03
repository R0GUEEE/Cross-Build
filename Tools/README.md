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

The helper constrains requested working directories to `--workspace` when supplied.
