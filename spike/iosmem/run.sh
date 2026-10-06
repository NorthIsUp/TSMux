#!/usr/bin/env bash
# Footprint (what jetsam counts on iOS) for N nodes, with and without GOMEMLIMIT.
set -euo pipefail
cd "$(dirname "$0")"
go build -o "$TMPDIR/iosmem" .
for limit in off 30MiB; do
  for n in 1 2 4; do
    out=$(mktemp)
    if [ "$limit" = off ]; then "$TMPDIR/iosmem" -n "$n" >"$out" & else GOMEMLIMIT=$limit "$TMPDIR/iosmem" -n "$n" >"$out" & fi
    until grep -q pid= "$out"; do sleep 1; done
    fp=$(footprint "$!" | awk '/Footprint:/ {print $(NF-5), $(NF-4)}')
    echo "limit=$limit $(cat "$out") footprint=$fp"
    kill "$!"
  done
done
