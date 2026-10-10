# hsctl

Manage the Headscale tailnet at `hs.asikmydeen.com` from any device, with no SSH
to the server. Plain POSIX `sh` and `curl`: macOS, Linux, OpenWrt/BusyBox, Termux.

```sh
hsctl preauthkeys create --reusable --expiration 7d   # prints the key
hsctl register hskey-authreq-XXXX                     # approve a waiting node
hsctl nodes list
```

On a phone, use Friday's Telegram `/mesh`. It goes through the same mint.

## Two credentials

| | mint token (`hsctl login --mint`) | API key (`hsctl login`) |
|---|---|---|
| Talks to | `/friday/mesh` sidecar on edge | Headscale `/api/v1` |
| Can do | mint 1h/8h/24h/48h/7d keys for `asik`, register nodes, list nodes | everything, including deleting nodes and rewriting ACL policy |
| Where it comes from | NAS `secrets/headscale/mint.env` (`HEADSCALE_MINT_TOKEN`) | on the server: `headscale apikeys create --expiration 365d` |
| Put it on | every device | as few machines as possible |

If both are saved, the API key is used. Set `HSCTL_BACKEND=mint` or `api` to force one.
Commands the mint cannot do (`users list`, `preauthkeys list|expire`, 90d keys,
other users, `--ephemeral`, `--tags`) fail locally with a message pointing at
`hsctl login`; no request is sent.

Credentials live in `${XDG_CONFIG_HOME:-~/.config}/hsctl/` with mode 600. The
token reaches `curl` through a config on stdin, so it never shows up in `ps`.

## Install

See [INSTALL.md](INSTALL.md).

## Tests

```sh
test/run.sh            # /bin/sh
test/run.sh /bin/dash  # stricter POSIX shell
HSCTL_PATH=/some/dir/without/jq/or/python3 test/run.sh /bin/dash   # sed-only JSON path, as on OpenWrt
```

The tests run against `test/fake_headscale.py`, a stand-in for the Headscale
v0.29 REST API and the mint sidecar. Like the real server, it alternates
compact and spaced JSON, because protojson randomises whitespace.
