#!/bin/sh
# Runs the checks on the native display, under the clone's own Ruby and gems.
#   checks/run.sh            every check
#   checks/run.sh walk       one (checks/walk.sspec)
# Each case runs in a sandbox that knows nothing of this folder, so the checks name it as
# __DIEM_ROOT__ and run from copies with the real path filled in.
D="$(cd "$(dirname "$0")/.." && pwd)"
SCARPE="${SCARPE:-$HOME/scarpe}"
RUBY="$(cd "$SCARPE" && rbenv which ruby 2>/dev/null || ruby -e 'print RbConfig.ruby')"
OUT="${TMPDIR:-/tmp}/scarpe-diem-checks"
mkdir -p "$OUT"
for f in "$D"/checks/*.sspec; do
  sed "s#__DIEM_ROOT__#$D#g" "$f" > "$OUT/$(basename "$f")"
done
if [ $# -eq 0 ]; then set -- "$OUT"; else set -- $(for n in "$@"; do echo "$OUT/$(basename "$n" .sspec).sspec"; done); fi
cd "$D" && BUNDLE_GEMFILE="$SCARPE/Gemfile" exec "$RUBY" -rbundler/setup "$SCARPE/spec/run" --display native "$@"
