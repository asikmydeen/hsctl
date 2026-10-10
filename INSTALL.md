# Installing hsctl

Every install downloads over HTTPS from GitHub. Don't fetch it over plain
HTTP: a tampered copy would read your saved credential the first time it runs.

## macOS / Linux

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/asikmydeen/hsctl/main/hsctl -o ~/.local/bin/hsctl
chmod 755 ~/.local/bin/hsctl
hsctl login --mint        # paste HEADSCALE_MINT_TOKEN from NAS secrets/headscale/mint.env
```

If `hsctl` isn't found, add `~/.local/bin` to `PATH`.

## Android (Termux)

```sh
pkg install curl
curl -fsSL https://raw.githubusercontent.com/asikmydeen/hsctl/main/hsctl -o "$PREFIX/bin/hsctl"
chmod 755 "$PREFIX/bin/hsctl"
hsctl login --mint
```

No Termux? Use Friday's Telegram `/mesh`. It goes through the same mint.

## OpenWrt router

Needs `curl` and `ca-bundle` (both on GL.iNet firmware). Without `ca-bundle`,
curl refuses the TLS connection rather than skipping verification.

```sh
curl -fsSL https://raw.githubusercontent.com/asikmydeen/hsctl/main/hsctl -o /usr/bin/hsctl
chmod 755 /usr/bin/hsctl
echo /usr/bin/hsctl >> /etc/sysupgrade.conf   # keep it across firmware upgrades
```

## Updating

Run the same `curl` line again. To check a download against a known copy,
compare `shasum -a 256 hsctl` (macOS) or `sha256sum hsctl` (Linux).

## Joining a new device

Mint a key on any device that has `hsctl`, then use it on the new device:

```sh
hsctl preauthkeys create --expiration 1h            # on a device with hsctl
tailscale up --login-server=https://hs.asikmydeen.com --authkey=<key> --accept-dns=false
```

You can skip the key: start the login on the new device, then approve the
`hskey-authreq-…` it shows with `hsctl register <text>`.
