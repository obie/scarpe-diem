#!/bin/sh
SCARPE="${SCARPE:-$HOME/scarpe}"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BOX="${SCARPE_HOME:-${TMPDIR:-/tmp}/scarpe-home-$(basename "$APP_DIR")}"
RUBY="$(cd "$SCARPE" && ruby -e 'print RbConfig.ruby')"
mkdir -p "$BOX"
exec env PATH="$SCARPE/spec/support/fakebin:$PATH" HOME="$BOX" \
  SPEC_TRAP_FILE="$BOX/trapped.txt" SPEC_CLIPBOARD_FILE="$BOX/clipboard.txt" \
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
  BUNDLE_GEMFILE="$SCARPE/Gemfile" "$RUBY" "$SCARPE/exe/scarpe" "$@" --dev
