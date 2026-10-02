#!/bin/sh
# Pictures of one scene at given seconds into it, headless, exact (no timers run between them).
#   DIEM_SCENE=Plasma tools/shots.sh 0,2.5,5 [scale]   -> shots/lab/plasma-<song time>.png
D="$(cd "$(dirname "$0")/.." && pwd)"
SCARPE="${SCARPE:-$HOME/scarpe}"
BOX="${SCARPE_HOME:-${TMPDIR:-/tmp}/scarpe-home-scarpe-diem}"
RUBY="$(cd "$SCARPE" && ruby -e 'print RbConfig.ruby')"
mkdir -p "$BOX" "$D/shots/lab"
exec env PATH="$SCARPE/spec/support/fakebin:$PATH" HOME="$BOX" \
  SPEC_TRAP_FILE="$BOX/trapped.txt" SPEC_CLIPBOARD_FILE="$BOX/clipboard.txt" \
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
  SCARPE_DISPLAY_SERVICE=native SCARPE_NATIVE_HEADLESS=1 SCARPE_NATIVE_ARGS="${SCARPE_NATIVE_ARGS:---fonts bundled}" \
  DIEM_LAB_SHOTS="$1" DIEM_SCALE="${2:-1}" DIEM_OUT="$D/shots/lab" \
  BUNDLE_GEMFILE="$SCARPE/Gemfile" "$RUBY" "$SCARPE/exe/scarpe" --native "${DIEM_LAB_FILE:-$D/lab.rb}" --dev
