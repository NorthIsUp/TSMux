#!/usr/bin/env bash
# Human-run: pushes the signing material to GitHub Actions secrets.
#
# An agent cannot run this — `gh secret set` is blocked in auto mode, and it
# should be: this is the one place the private key leaves the machine. Run it
# yourself and the agent never touches the values.
#
#   ./scripts/set-ci-secrets.sh [owner/repo]
#
# The Developer ID certificate is per team, so this is the same material clip.md
# uses; the shared team directory is the source rather than a second export.
set -euo pipefail
cd "$(dirname "$0")/.."

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
team_dir="${TEAM_DIR:-$HOME/.appstoreconnect/clipmd}"
: "${ASC_KEY_ID:=238ATU74S4}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"

for f in "$key" "$team_dir/devid.p12" "$team_dir/p12.pass"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

echo "==> setting secrets on $repo"
gh secret set ASC_KEY_P8    --repo "$repo" < "$key"
gh secret set P12_PASSWORD  --repo "$repo" < "$team_dir/p12.pass"
base64 -i "$team_dir/devid.p12" | gh secret set DEVID_P12 --repo "$repo"

echo "==> done; secrets now on $repo:"
gh secret list --repo "$repo"
