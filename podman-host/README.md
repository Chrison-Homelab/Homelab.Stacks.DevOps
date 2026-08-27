# DevOps podman host (CT 3006)

The DevOps stack's rootless Podman + quadlet host, per [ADR-0009](../../../docs/adr/ADR-0009-container-runtime.md)
and [#447](https://github.com/Chrison-Homelab/Homelab/issues/447). Pinned to **hpe-01** —
the stack default `desktop-01` is the on-demand sleep node ([#191](https://github.com/Chrison-Homelab/Homelab/issues/191)),
which would be asleep exactly when a scheduled sweep wanted the browser.

| Quadlet | What it is | Ports |
|---|---|---|
| `chromium` | Persistent Chromium with a CDP endpoint, for `~/marketplace-tools` | CDP `127.0.0.1:9222` · KasmVNC `:3010` / `:3011` |

Further DevOps tooling joins as **extra quadlets in `quadlets/`**, not as new one-app CTs.
There is deliberately no `.network` unit: a single container needs no by-name DNS, and one
gets added the moment a second container has to resolve the first (see the Monitoring
host's `monitoring.network` for why it becomes mandatory then).

## Deploy

```bash
set -a && . ./secrets.env && set +a    # CHROMIUM_KASM_USER + CHROMIUM_KASM_PASSWORD
./build.sh Preview --stack DevOps      # dry-run
./build.sh Deploy  --stack DevOps      # live apply
```

Config is **not** baked into the guest — the quadlets are rendered onto the host and folded
into the managed marker, so editing one re-converges and restarts the unit that consumes it.

## One-off: log Chromium into Facebook

The KasmVNC UI exists for exactly this. It is the only interactive surface.

1. Open `http://devops-podman-host.homelab.chrison.internal:3010` (or `https://…:3011`,
   self-signed) and authenticate with `CHROMIUM_KASM_USER` / `CHROMIUM_KASM_PASSWORD`.
2. Log into Facebook by hand, and complete any 2FA challenge.
3. That's it — the session persists in the `/config` volume across restarts.

> ⚠ **Do not copy `~/marketplace-tools/profile/` into the volume.** Moving a session onto a
> new device fingerprint is very likely to trip Facebook's new-device check, and can cost a
> checkpoint or a temporary lockout on the account. Logging in fresh takes two minutes.

Trade Me needs no login for scraping. (Note that this also means the container cannot add
things to a Trade Me *watchlist* — that has bitten us before, when clicks were reported as
successful against a profile that was only ever logged into Facebook.)

## Using it from the workstation

`~/marketplace-tools/lib.js` honours **`CDP_URL`** (default `http://127.0.0.1:9222`), so
every script — `scan.js`, `watch.js`, `detail.js`, `search.js`, `trademe.js` — picks this up
with no further change.

```bash
ssh -N -L 9222:127.0.0.1:9222 root@devops-podman-host.homelab.chrison.internal &
CDP_URL=http://127.0.0.1:9222 node ~/marketplace-tools/scan.js
```

### ⚠ The obvious tunnel is the wrong one

```bash
# WRONG — forwards to hpe-01's OWN loopback, where nothing is listening.
ssh -N -L 9222:127.0.0.1:9222 root@hpe-01.homelab.chrison.internal
```

CDP is published on **CT 3006's** loopback, not the node's. The tunnel must terminate
*inside the CT*, so SSH to the CT itself. If the CT is not directly reachable, jump:

```bash
ssh -N -J root@hpe-01.homelab.chrison.internal \
       -L 9222:127.0.0.1:9222 root@10.10.204.36 &
```

Rewriting the quadlet to publish on the CT's LAN address so that the node-level tunnel
"just works" would expose an unauthenticated CDP port to everything on VLAN 1010. Don't.

## Why loopback-only is not paranoia

The DevTools protocol has **no authentication of any kind** — no token, no password, no
ACL. Anything that can open a TCP connection to 9222 gets full control of a browser holding
a live Facebook session: reading DMs, posting and editing listings, changing account
settings. Port 9222 is equivalent to the account password, and should be treated that way.

The KasmVNC UI is the deliberate exception — it must be reachable to be useful — which is
why `CUSTOM_USER`/`PASSWORD` are non-optional. That basic auth is the only thing between
VLAN 1010 and the session.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `connectOverCDP` hangs or refuses | Tunnel terminates on the node, not the CT — see above. |
| **403 on `/json/version`**, everything else healthy | Chrome rejects DevTools requests whose `Host` header is not `localhost`/a bare IP (DNS-rebinding defence). The access path must be an SSH tunnel presenting `localhost:9222`, never a reverse proxy on a hostname. |
| Tabs crash, blank screenshots, "Target closed" mid-navigation | `/dev/shm` too small. Reads like a scraper bug; it isn't. `ShmSize=1g` in the quadlet. |
| Container exits immediately at startup | Chrome's sandbox vs. the nested userns — `SecurityOpt=seccomp=unconfined` is required. Last resort `CHROME_CLI=--no-sandbox`, which disables the renderer sandbox. |
| Unit absent after a CT reboot | Missing `[Install] WantedBy=default.target` (gotcha 6). Note also that quadlets do not start for ~92s after boot because `network-online.target` is never reached — gotcha 7, handled by the provisioner. |
| Trade Me returns `ERR_BLOCKED_BY_RESPONSE` | Rate limiting, not a container fault. The scripts back off 30/60/90s; pace multi-page runs with `DELAY=6000`. |
| Selectors break, pages look mobile | Viewport too narrow — both sites are responsive and switch DOM. `CUSTOM_WIDTH/HEIGHT` are set to 1920×1080 for this reason. |

## What this unblocks

A sweep that runs **on the homelab** rather than the laptop, which is the actual point:

```bash
node ~/marketplace-tools/scan.js nodes >> /var/log/marketplace-scan.log
```

Driven by a systemd timer on the node instead of a human remembering. The "check back
before the auction closes" case has been impossible until now: a cloud agent cannot reach
the laptop, and Trade Me is a client-rendered SPA, so plain HTTP fetches return no live bid
data.
