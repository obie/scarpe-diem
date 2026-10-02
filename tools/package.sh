#!/bin/sh
# Builds dist/Scarpe Diem.app and dist/Scarpe Diem.dmg with Scarpe's packager (macOS, Apple silicon).
# Run it with your real HOME: the packager keeps its Ruby runtime in ~/.scarpe/packager-cache.
D="$(cd "$(dirname "$0")/.." && pwd)"
SCARPE="${SCARPE:-$HOME/scarpe}"
cd "$SCARPE" && exec bundle exec ruby exe/scarpe package "$D/scarpe_diem.rb" --native --dmg \
  --name "Scarpe Diem" --icon "$D/icon/icon_final.png" --include lib --output "$D/dist"
