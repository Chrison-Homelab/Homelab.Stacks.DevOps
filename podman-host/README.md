# DevOps podman host (CT 3006)

The DevOps stack's rootless Podman + quadlet host, per [ADR-0009](../../../docs/adr/ADR-0009-container-runtime.md)
and [#447](https://github.com/Chrison-Homelab/Homelab/issues/447). Pinned to **hpe-01** —
the stack default `desktop-01` is the on-demand sleep node ([#191](https://github.com/Chrison-Homelab/Homelab/issues/191)),
which would be asleep exactly when a scheduled sweep wanted the browser.

| Quadlet | What it is | Ports |
|---|---|---|
| `chromium` | Persistent Chromium with a CDP endpoint, for `~/marketplace-tools` | CDP `127.0.0.1:9222` (CT loopback) · KasmVNC `:3000` / `:3001` |

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

1. Open **`http://<ct-ip>:3000`** (or `https://<ct-ip>:3001`, self-signed) and authenticate
   with `CHROMIUM_KASM_USER` / `CHROMIUM_KASM_PASSWORD` from `secrets.env`.
   The shape reserves `10.10.204.36`, but a freshly-created CT keeps its original lease
   until it renews — check the current address with `pct exec 3006 -- hostname -I`.
2. Log into Facebook by hand, and complete any 2FA challenge.
3. That's it — the session persists in the `/config` volume across restarts.

> ⚠ **Do not copy `~/marketplace-tools/profile/` into the volume.** Moving a session onto a
> new device fingerprint is very likely to trip Facebook's new-device check, and can cost a
> checkpoint or a temporary lockout on the account. Logging in fresh takes two minutes.

Trade Me needs no login for scraping. (Note that this also means the container cannot add
things to a Trade Me *watchlist* — that has bitten us before, when clicks were reported as
successful against a profile that was only ever logged into Facebook.)

## Using it from the workstation

`~/marketplace-tools/lib.js` honours **`CDP_URL`** (default `http://127.0.0.1:9222`), so every
script — `scan.js`, `watch.js`, `detail.js`, `search.js`, `trademe.js` — picks this up with no
code change.

```bash
node ~/marketplace-tools/cdp-tunnel.js &                     # 127.0.0.1:9222 -> CT 3006
CDP_URL=http://127.0.0.1:9222 node ~/marketplace-tools/scan.js
```

### ⚠ `ssh -L` does not work here, and cannot

Three facts rule it out, and each one on its own is enough:

1. **Chrome refuses to bind DevTools off localhost.** Modern Chrome (verified on 151) ignores
   `--remote-debugging-address` — the flag appears on the cmdline and Chrome binds
   `127.0.0.1:9222` anyway. So CDP lives on the *container's* loopback and cannot be published,
   proxied or bound to the LAN even deliberately. This is why the quadlet uses `Network=host`:
   it makes Chrome's own localhost bind land on the CT's loopback.
2. **This CT has no sshd.** It is a rootless-podman host driven entirely over `pct exec`, so
   `ssh -L 9222:127.0.0.1:9222 root@<ct-ip>` has nothing to connect to. `authorizedKeys` is a
   `shell`-provisioner feature, not part of the `podman` app.
3. **`ssh -L … root@hpe-01` forwards to the NODE's loopback**, where nothing is listening.

So `cdp-tunnel.js` listens on the workstation's loopback and, per connection, splices stdio
through `ssh <node> pct exec 3006 -- nc 127.0.0.1 9222`. Nothing new listens in the CT, the LAN
never sees 9222, and no credential is added anywhere. Knobs: `NODE_HOST`, `CTID`, `PORT`.

> If `cdp-tunnel.js` reports `EADDRINUSE`, a local Chrome from `launch.js` still holds 9222.
> Close it, or use `PORT=9333` and point `CDP_URL` at the same port.

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
| `connectOverCDP` hangs or refuses | `cdp-tunnel.js` not running, or you tried `ssh -L` — see above for why that cannot work. |
| **403 on `/json/version`**, everything else healthy | Chrome rejects DevTools requests whose `Host` header is not `localhost`/a bare IP (DNS-rebinding defence). `cdp-tunnel.js` presents `localhost:9222`, which is fine — but a reverse proxy on a hostname would be refused. |
| Tabs crash, blank screenshots, "Target closed" mid-navigation | `/dev/shm` too small. Reads like a scraper bug; it isn't. `ShmSize=1g` in the quadlet. |
| Container exits immediately at startup | Chrome's sandbox vs. the nested userns — `PodmanArgs=--security-opt seccomp=unconfined` is required. Last resort `CHROME_CLI=--no-sandbox`, which disables the renderer sandbox. |
| **`Unit chromium.service not found`** | Quadlet rejected the file over ONE unsupported key and generated nothing. `SecurityOpt=` is not a quadlet key (use `PodmanArgs=--security-opt …`). Diagnose in one second with `/usr/libexec/podman/quadlet -dryrun -user` as the `podman` user. |
| CDP silent but container healthy, Chrome flags correct, curl works *inside* the container | Chrome bound its own loopback and the publish forwarded to an interface nothing listens on. Needs `Network=host`. |
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
