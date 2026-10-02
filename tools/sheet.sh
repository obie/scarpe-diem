#!/bin/sh
# A contact sheet of one scene: shots at the given seconds into it, tiled with labels.
#   DIEM_SCENE=Plasma tools/sheet.sh 0,2,4,6,8,10,12,14 [scale]  -> shots/sheets/plasma.png
D="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$(echo "$DIEM_SCENE" | tr '[:upper:]' '[:lower:]')"
OUT="$D/shots/sheets"; mkdir -p "$OUT"
FILES=$("$D/tools/shots.sh" "$1" "${2:-1}" | grep '\.png$') || exit 1
LABELS=""
set --
for f in $FILES; do set -- "$@" -label "$(basename "$f" .png)" "$f"; done
magick montage "$@" -tile 4x -geometry 480x270+6+6 -background '#111' -fill '#ddd' -pointsize 14 "$OUT/$NAME.png" && echo "$OUT/$NAME.png"
