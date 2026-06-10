# BPF CI for stable kernels

Runs BPF selftests against released Linux **stable** kernels.

This repo is the *infrastructure*: it syncs upstream stable trees into branches
and overlays the CI code onto them. The actual test (kernel build, selftests,
denylists, version-specific `ci/diffs`) lives under `ci/` and in the CI workflow
and is owned by the stable-BPF-testing effort. The CI workflow is currently a
**demo stub** (see [Status](#status)).

## Branch model

| Branch | Contents | Edited by |
|--------|----------|-----------|
| `main` | CI source only — `.github/` (workflows + sync script) and `ci/` (test config). No kernel source. | Humans, via PR |
| `linux-X.Y.y` | A released stable kernel (source at the repo root) with `.github/` + `ci/` overlaid. | Machine-generated |

`.github/workflows/sync-upstream.yml` regenerates each `linux-X.Y.y` branch:

```
<released linux-X.Y.y tip, from stable/linux.git>
  + apply stable-queue queue-X.Y/   (best effort)
  + overlay .github + ci from main
```

and force-pushes it. The CI workflow file rides along on the branch (via the
overlay), so the push triggers CI on that exact kernel snapshot — GitHub Actions
runs the workflow as it exists on the pushed branch.

> **CI-code edits go to `main`.** The `linux-X.Y.y` branches are disposable and
> force-overwritten every sync; committing to them directly is futile.

## Tracked versions

`7.0, 6.18, 6.12, 6.6, 6.1` (newest stable + active LTS; floor at 6.1) — the
matrix in `sync-upstream.yml`. Versions that leave stable-queue's
`active_kernel_versions` are skipped automatically.

## Operating it

- **Sync now:** run the *Sync upstream stable* workflow (dispatch); pass
  `versions: "6.12 6.6"` for a subset.
- Otherwise it runs daily and on every push to `main` (to propagate CI changes).
- Unchanged versions are a no-op: the sync compares the resulting git *tree* and
  skips the push (and the CI run) when nothing changed.

## Status

`.github/workflows/test.yml` is a **stub**: on our bare-metal runners it prints
the branch/revision under test and the overlaid `ci/` config, demonstrating the
plumbing end to end. The kernel build + selftest run are left to be filled in.

## Requirements

- A GitHub App bot token (`KPD_BOT_APP_ID` / `KPD_BOT_PRIVATE_KEY` secrets): the
  sync job pushes with it so the push triggers CI (the default `GITHUB_TOKEN`
  would not).
- Self-hosted runners from `kernel-patches/runner` for the CI job.
