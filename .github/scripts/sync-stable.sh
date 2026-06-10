#!/usr/bin/env bash
#
# Sync one upstream Linux *stable* version into a CI branch in this repo.
#
# Usage: sync-stable.sh <version>          # e.g. sync-stable.sh 6.6
#
# For version X.Y this produces (and force-pushes) the branch `linux-X.Y.y`:
#
#     <released linux-X.Y.y tip>
#         -> stable-queue: apply queue-X.Y (best effort)
#             -> ci: overlay .github + ci from `main`
#
# i.e. the branch carries the kernel source at its root with this repo's CI
# code overlaid on top, so a push to it triggers the CI workflow (test.yml).
#
# Incrementality: we seed the working clone from the *already-published*
# `linux-X.Y.y` branch (which carries the previous sync's kernel, served by our
# own GitHub repo). The subsequent fetch from kernel.org then only transfers the
# delta since the last sync. The first sync of a version is the one unavoidable
# full fetch from kernel.org.
#
# Notes:
#   * The push uses $GITHUB_TOKEN, which MUST be a GitHub App installation token
#     -- a push made with the default Actions GITHUB_TOKEN would NOT trigger the
#     downstream workflow.
#   * Version branches are disposable: they are force-regenerated every run.
#     All CI-code edits must go to `main` (which this script overlays).
#   * An unchanged version is a no-op: the resulting tree is compared against
#     what is published and the push (and therefore the CI run) is skipped.

set -euo pipefail

VERSION="${1:?usage: sync-stable.sh <version>  (e.g. 6.6)}"

REPO="${REPO:-kernel-patches/linux-stable}"
CI_SOURCE_BRANCH="${CI_SOURCE_BRANCH:-main}"
STABLE_URL="${STABLE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
QUEUE_URL="${QUEUE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/stable-queue.git}"

BOT_NAME="${BOT_NAME:-bpf-ci[bot]}"
BOT_EMAIL="${BOT_EMAIL:-bot+bpf-ci@kernel.org}"

UPSTREAM_BRANCH="linux-${VERSION}.y"
OUTPUT_BRANCH="linux-${VERSION}.y"

: "${GITHUB_TOKEN:?GITHUB_TOKEN (a GitHub App installation token) is required to push}"
PUSH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---------------------------------------------------------------------------
# 1. Seed the working clone. Prefer the existing version branch (it already
#    carries the kernel from the last sync, served by our GitHub repo) so the
#    upstream fetch in step 3 is incremental; fall back to `main` on first run.
# ---------------------------------------------------------------------------
if git ls-remote --exit-code --heads "${PUSH_URL}" "${OUTPUT_BRANCH}" >/dev/null 2>&1; then
    seed_branch="${OUTPUT_BRANCH}"
    have_published=1
else
    seed_branch="${CI_SOURCE_BRANCH}"
    have_published=0
fi

echo "::group::Clone ${seed_branch} of ${REPO}"
git clone --no-tags --single-branch --branch "${seed_branch}" "${PUSH_URL}" "${workdir}/repo"
cd "${workdir}/repo"
git config user.name "${BOT_NAME}"
git config user.email "${BOT_EMAIL}"

if [[ "${have_published}" -eq 1 ]]; then
    old_head="$(git rev-parse HEAD)"
    old_tree="$(git rev-parse 'HEAD^{tree}')"
fi

# We always need `main`'s CI tree to overlay; fetch it (tiny).
git fetch --no-tags origin "+refs/heads/${CI_SOURCE_BRANCH}:refs/remotes/origin/${CI_SOURCE_BRANCH}"
CI_REF="$(git rev-parse "refs/remotes/origin/${CI_SOURCE_BRANCH}")"
echo "CI source ${CI_SOURCE_BRANCH} @ ${CI_REF}"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 2. EOL gate + stable-queue checkout. stable-queue lists the actively
#    maintained versions in active_kernel_versions; if ours is gone, skip.
#    A separate shallow/sparse clone keeps this cheap and isolated from the
#    kernel working tree. (No --filter: kernel.org ignores it; --depth=1 keeps
#    it to a single snapshot.)
# ---------------------------------------------------------------------------
echo "::group::Fetch stable-queue (queue-${VERSION})"
qrepo="${workdir}/stable-queue"
git clone --no-tags --depth=1 --single-branch --branch master --sparse "${QUEUE_URL}" "${qrepo}"
# Cone-mode sparse-checkout always includes top-level files (active_kernel_versions);
# add this version's queue directory.
git -C "${qrepo}" sparse-checkout set "queue-${VERSION}"

if ! grep -qxF "${VERSION}" "${qrepo}/active_kernel_versions"; then
    echo "::warning::stable ${VERSION} is not in active_kernel_versions (EOL?), skipping"
    exit 0
fi
echo "${VERSION} is actively maintained"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 3. Check out the released upstream tip as the base of the version branch.
#    Incremental when seeded from the existing version branch (step 1).
# ---------------------------------------------------------------------------
echo "::group::Fetch upstream ${UPSTREAM_BRANCH}"
git remote add stable "${STABLE_URL}"
git fetch --no-tags stable \
    "+refs/heads/${UPSTREAM_BRANCH}:refs/remotes/stable/${UPSTREAM_BRANCH}"
base_commit="$(git rev-parse "refs/remotes/stable/${UPSTREAM_BRANCH}")"
git checkout -q -B "${OUTPUT_BRANCH}" "${base_commit}"
echo "Released tip ${UPSTREAM_BRANCH} @ ${base_commit}"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. Apply the queued stable patches (best effort, mirroring the in-job logic
#    Shung-Hsi uses today: dry-run, then apply; skip anything that does not
#    apply cleanly).
# ---------------------------------------------------------------------------
echo "::group::Apply stable-queue queue-${VERSION}"
applied=0
qseries="${qrepo}/queue-${VERSION}/series"
if [[ -f "${qseries}" ]]; then
    while read -r patch; do
        [[ -z "${patch}" ]] && continue
        p="${qrepo}/queue-${VERSION}/${patch}"
        if patch --dry-run -N --silent -p1 -s < "${p}" 2>/dev/null; then
            patch -s -p1 < "${p}"
            applied=$((applied + 1))
            echo "applied  ${patch}"
        else
            echo "skip     ${patch} (does not apply cleanly)"
        fi
    done < "${qseries}"
else
    echo "no queue-${VERSION}/series in stable-queue; nothing to apply"
fi
if [[ "${applied}" -gt 0 ]]; then
    git add -A
    git commit -q -m "stable-queue: apply queue-${VERSION} (${applied} patches) over ${UPSTREAM_BRANCH}@$(git rev-parse --short "${base_commit}")"
fi
echo "applied ${applied} queued patch(es)"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 5. Overlay this repo's CI code (.github AND ci) from `main`. Using checkout
#    (not merge) because `main` shares no history with the kernel tree.
# ---------------------------------------------------------------------------
echo "::group::Overlay .github + ci from ${CI_SOURCE_BRANCH}"
git checkout "${CI_REF}" -- .github ci
git add .github ci
git commit -q -m "ci: overlay .github+ci from ${CI_SOURCE_BRANCH}@$(git rev-parse --short "${CI_REF}")"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 6. Idempotency + push. Compare the resulting *tree* (which captures the
#    upstream tip, the queue-apply result, and the CI overlay) against what is
#    already published; skip the push -- and therefore the CI run -- if equal.
# ---------------------------------------------------------------------------
echo "::group::Push ${OUTPUT_BRANCH}"
new_tree="$(git rev-parse 'HEAD^{tree}')"
if [[ "${have_published}" -eq 1 ]]; then
    if [[ "${old_tree}" == "${new_tree}" ]]; then
        echo "${OUTPUT_BRANCH}: tree unchanged (${new_tree}); skipping push"
        exit 0
    fi
    git push --force-with-lease="refs/heads/${OUTPUT_BRANCH}:${old_head}" \
        "${PUSH_URL}" "HEAD:refs/heads/${OUTPUT_BRANCH}"
else
    git push "${PUSH_URL}" "HEAD:refs/heads/${OUTPUT_BRANCH}"
fi
echo "pushed ${OUTPUT_BRANCH} (tree ${new_tree})"
echo "::endgroup::"
