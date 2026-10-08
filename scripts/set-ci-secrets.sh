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

sparkle_key="${SPARKLE_KEY:-$HOME/.appstoreconnect/tsmux/sparkle_ed_priv}"

for f in "$key" "$team_dir/devid.p12" "$team_dir/installer.p12" "$team_dir/p12.pass" "$sparkle_key"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

echo "==> setting secrets on $repo"
gh secret set ASC_KEY_P8    --repo "$repo" < "$key"
gh secret set P12_PASSWORD  --repo "$repo" < "$team_dir/p12.pass"
base64 -i "$team_dir/devid.p12" | gh secret set DEVID_P12 --repo "$repo"
# Signs the Mac App Store .pkg; same password as the Developer ID p12.
base64 -i "$team_dir/installer.p12" | gh secret set INSTALLER_P12 --repo "$repo"
# Signs every Sparkle update. Losing it means shipping a new public key in a
# build users have to install by hand; leaking it means someone else can.
gh secret set SPARKLE_ED_KEY --repo "$repo" < "$sparkle_key"

# iOS: the team's Apple Distribution p12 lives in its bundled 1Password item
# (read in one session, by id: op:// splits labels on dots); the two App Store
# profiles are per app and come from make_profile.py's output on disk.
op_account="${OP_ACCOUNT:-mony-hitchcock}"
op_item="${OP_ITEM:-hoo5lzo6l6sotm77acfcnojg5q}"
op_p12_file="${OP_P12_FILE:-cyhrdaeqyz22dm2yfndqlwst7i}"
ios_dir="${IOS_DIR:-$HOME/.appstoreconnect/tsmux}"
for f in "$ios_dir/app.mobileprovision" "$ios_dir/tunnel.mobileprovision" \
  "$ios_dir/mac-app.provisionprofile" "$ios_dir/mac-tunnel.provisionprofile" \
  "$ios_dir/direct-app.provisionprofile" "$ios_dir/direct-tunnel.provisionprofile"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
op item get "$op_item" --vault Private --account "$op_account" --reveal --format json > "$tmp/item.json"
op read --account "$op_account" --out-file "$tmp/dist.p12" "op://Private/$op_item/$op_p12_file" >/dev/null
jq -er '.fields[] | select(.label == "Distribution p12 password") | .value' "$tmp/item.json" \
  | tr -d '\n' | gh secret set DIST_P12_PASSWORD --repo "$repo"
base64 -i "$tmp/dist.p12" | gh secret set DIST_P12_BASE64 --repo "$repo"
base64 -i "$ios_dir/app.mobileprovision" | gh secret set APP_PROFILE_BASE64 --repo "$repo"
base64 -i "$ios_dir/tunnel.mobileprovision" | gh secret set TUNNEL_PROFILE_BASE64 --repo "$repo"
base64 -i "$ios_dir/mac-app.provisionprofile" | gh secret set MAC_APP_PROFILE_BASE64 --repo "$repo"
base64 -i "$ios_dir/mac-tunnel.provisionprofile" | gh secret set MAC_TUNNEL_PROFILE_BASE64 --repo "$repo"
# The Developer ID Mac app and its system extension: their entitlements need a
# profile even outside the App Store.
base64 -i "$ios_dir/direct-app.provisionprofile" | gh secret set DIRECT_APP_PROFILE_BASE64 --repo "$repo"
base64 -i "$ios_dir/direct-tunnel.provisionprofile" | gh secret set DIRECT_TUNNEL_PROFILE_BASE64 --repo "$repo"

# The daily tailscale-update job opens its PR with this. GITHUB_TOKEN cannot be
# used: a PR it opens does not trigger `on: pull_request`, so ci.yml would never
# run and automerge would wait on checks that never start. A fine-grained PAT
# with contents:write + pull-requests:write on this repo is enough.
if [ -n "${PR_TOKEN:-}" ]; then
  printf '%s' "$PR_TOKEN" | gh secret set PR_TOKEN --repo "$repo"
  echo "==> set PR_TOKEN"
else
  gh secret list --repo "$repo" | grep -q '^PR_TOKEN' \
    || echo "note: PR_TOKEN not set and not in env — the daily update job will fail until it is" >&2
fi

echo "==> done; secrets now on $repo:"
gh secret list --repo "$repo"
