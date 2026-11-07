#!/usr/bin/env bash
# Publishes the open-source part of this repository to the public GitHub repository as a linear history of
# snapshots. The public tree is everything except the content service (website/: worker, licence issuer, Stripe)
# and the internal planning documents (docs/). Each run syncs the current HEAD's public paths into the `public`
# branch (a worktree at ../offline-vault-public), commits when something changed, and pushes to the `public` remote.
#
#   scripts/publish_public.sh            # sync, commit, push
#   scripts/publish_public.sh --dry-run  # sync and show the diff, push nothing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_REMOTE="${PUBLIC_REMOTE:-public}"
WORKTREE="${PUBLIC_WORKTREE:-$ROOT/../offline-vault-public}"
PUBLIC_PATHS=(Core OfflineVault OfflineVault.xcodeproj ovsync fixture scripts README.md project.yml LICENSE .gitignore)
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$ROOT" remote get-url "$PUBLIC_REMOTE" >/dev/null 2>&1 || { echo "no remote '$PUBLIC_REMOTE'; add it: git remote add public https://github.com/nc/offlinevault.git" >&2; exit 2; }
if [[ ! -d "$WORKTREE" ]]; then
  if git -C "$ROOT" show-ref --verify --quiet refs/heads/public; then git -C "$ROOT" worktree add "$WORKTREE" public
  else git -C "$ROOT" worktree add --orphan -b public "$WORKTREE"; fi
fi

# Export exactly the committed public paths (never the working tree, so nothing untracked or ignored can leak).
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
git -C "$ROOT" archive HEAD "${PUBLIC_PATHS[@]}" | tar -x -C "$STAGE"
# Secrets never live in tracked files, and this proves it on every publish.
if grep -rIEn '(sk|rk)_(live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|CLOUDFLARE_API_TOKEN=[A-Za-z0-9_-]{20,}' "$STAGE" --exclude-dir=dev-keys; then
  echo "refusing to publish: the export contains something that looks like a secret (above)" >&2; exit 3
fi
rsync -a --delete --exclude .git "$STAGE"/ "$WORKTREE"/
git -C "$WORKTREE" add -A
if git -C "$WORKTREE" diff --cached --quiet; then echo "public tree unchanged at $SHA"; exit 0; fi
git -C "$WORKTREE" --no-pager diff --cached --stat | tail -3
if [[ $DRY == 1 ]]; then echo "dry run: not committing"; git -C "$WORKTREE" reset -q; exit 0; fi
git -C "$WORKTREE" commit -q -m "Public snapshot of $SHA" && git -C "$WORKTREE" push "$PUBLIC_REMOTE" public:main
echo "pushed public snapshot of $SHA"
