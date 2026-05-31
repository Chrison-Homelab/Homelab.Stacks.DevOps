# Homelab.Stacks.DevOps

Self-hosted source control + CI/CD, deployed as **community-scripts LXCs** (one
container per service) and defined as IaC shapes.

> Submodule of [Homelab](https://github.com/ChrisonSimtian/Homelab), mounted at
> `stacks/DevOps`. Plan: [BL-015](https://github.com/ChrisonSimtian/Homelab/issues/51).

## Members

CTID block **3000–3999** (declared in [`stack.yaml`](stack.yaml); members inherit its `defaults`).

| CTID | Member | Script | Channel | Status |
|------|--------|--------|---------|--------|
| 3000 | [forgejo](forgejo.lxc.yaml) | `ct/forgejo.sh` | stable | ready to deploy |
| 3001 | [forgejo-runner](forgejo-runner.lxc.yaml) | `ct/forgejo-runner.sh` | **dev** (ProxmoxVED) | ready — in-dev script |
| 3002 | [github-runner](github-runner.lxc.yaml) | `ct/github-runner.sh` | stable | ready (new, independent of CT 2005) |
| 3003 | woodpecker | — | — | **parked** — no community-script in either repo yet |

## Deploying

These are LXC shapes for the `homelab/v1` contract. Render/deploy from the parent
repo (which holds the schema + renderer):

```powershell
# from the Homelab checkout — dry-run by default:
./Infrastructure/deploy/Deploy-Shape.ps1 -ShapePath ./stacks/DevOps/forgejo.lxc.yaml
# add -Apply to deploy over SSH
```

Order: **forgejo (3000)** first, then **github-runner (3002)**, then
**forgejo-runner (3001)** (it registers against Forgejo).

Notes:
- Schema: [`Infrastructure/schema/shape.schema.json`](../../Infrastructure/schema/shape.schema.json) · renderer docs: [`Infrastructure/deploy/README.md`](../../Infrastructure/deploy/README.md).
- The existing github-runner **CT 2005** is intentionally left untouched / unmanaged.
- **Woodpecker** is reserved at 3003; a shape will be authored once a community script exists.
- Registration tokens / admin setup / TLS are **post-create** (manual for now) — see the plan's deferred tasks.
- NFS data hardening: [BL-016](https://github.com/ChrisonSimtian/Homelab/issues/52).

## Parking lot

Other DevOps-related bits (runner configs, CI templates, shared workflows, docs)
can live here too as the stack grows.
