# CLAUDE.md — Homelab.Stacks.DevOps

Guidance for Claude Code working in this repo.

## What this is

A **stack submodule** of [`Chrison-Homelab/Homelab`](https://github.com/Chrison-Homelab/Homelab),
mounted there at `stacks/DevOps` (meta-repo model, ADR-0008). This repo holds only the stack's own
shapes; the **converge/validate engine lives in the superproject** and is the only thing that
applies them.

> **Read the superproject's [`CLAUDE.md`](https://github.com/Chrison-Homelab/Homelab/blob/main/CLAUDE.md) first.**
> It carries the rules that apply here and are *not* repeated in this file: the PR-only git
> workflow + merge strategy (ADR-0010), the worktree rule for parallel sessions, the shared
> external-account guardrails (**add-only** — never touch Cloudflare/GitHub resources we didn't
> create), and `secrets.env` / Bitwarden Secrets Manager handling.

## This stack

Self-hosted **source control + CI/CD** — the forge and the runners that build everything else.

- **CTID block:** `3000–3999` (enforced by `stack.yaml`'s `ctidRange`)
- **Default node:** `desktop-01` — chosen for CI build muscle (12 cores, large `local-lvm`)
- **Network:** VLAN **1010** (Homelab)

| ID | Member | `app:` |
|---|---|---|
| 3000 | `forgejo` | `forgejo` — the Git forge; provisioner sets `ROOT_URL` |
| 3001 | `forgejo-runner` | `forgejo-runner` — registers against the forge post-create |
| 3002 | `github-runner` | `github-runner` — self-hosted runner registered to the GitHub org |
| 3004 | `cloudflared` | `cloudflared` — this stack's dedicated tunnel |

**Members must set `ctid` explicitly** — omission is an error. `ctid: auto` exists for rare cases
but has to be typed deliberately.

## Working here

Converge runs **from the superproject**, pointed at this directory — never from inside this repo:

```bash
# in the superproject
dotnet run --project Infrastructure/engine -- validate stacks/DevOps
dotnet run --project Infrastructure/engine -- converge stacks/DevOps          # dry run
dotnet run --project Infrastructure/engine -- converge stacks/DevOps --apply
```

Shapes validate against the superproject's `Infrastructure/schema/shape.schema.json`. This repo
also runs an opt-in `validate.yml` calling the superproject's reusable `_validate-shapes.yml`; it
needs the `SCHEMA_RO_PAT` Actions secret in scope for this repo.

## Gotchas specific to this stack

- **This stack hosts the runner that CI depends on** — changes here can take the superproject's CI
  down with them. The `github-runner` member is what serves `[self-hosted, homelab]` jobs, so
  treat its shape as load-bearing and prefer side-by-side over in-place changes.
- **Runner registration is a post-create provisioner action**, not something to do by hand. The
  forge runner pulls a registration token from its `forgejo` dependency via `dependsOn`; the
  GitHub runner registers to the org. Re-running converge is the way to re-register.
- **The tunnel is this stack's own** (ADR-0005, per-stack tunnels). Don't point it at other
  stacks' services or extend a different stack's tunnel to reach these.
- **An internal NuGet feed (BaGet) is planned for this stack** — superproject issue #292.
