# BPF CI for stable kernels

This repository implements BPF CI testing for released Linux **stable** kernels.

The per-version kernel branches are synced and tests are triggered on push.

## Branches

CI code lives on the `main` branch, no Linux code is committed there.

`linux-X.Y.y` branches track corresponding released stable kernel.

`.github` and `ci` directories from `main` are overlaid on top of every stable version branch on every sync.

`mainline` mirrors [torvalds/master](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/log/), it's a shared-history base for the stable branches.

## How it works

`.github/workflows/sync-upstream.yml` runs daily and on every push to `main`:

1. `mainline` is refreshed from torvalds `master`.
2. Each tracked `linux-X.Y.y` branch is regenerated from the released stable tip +
   queued stable-queue patches (`git am`) + the CI code overlaid from `main`, then
   pushed.

The push to a `linux-X.Y.y` branch triggers `.github/workflows/test.yml`.

## Tracked versions

`7.0 6.18 6.12 6.6 6.1` — newest stable plus active LTS (floor 6.1).
