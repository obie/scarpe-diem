#!/bin/sh
# usage: ./bench.sh app.rb SECS [extra renderer args]   -> ghost run with stats summary
APP="$1"; SECS="${2:-5}"; shift; [ $# -gt 0 ] && shift
D="$(cd "$(dirname "$0")" && pwd)/shots/stats/$(basename "$APP" .rb)-$(date +%s)-$$"
mkdir -p "$D"
SCARPE_NATIVE_STATS="$D" SCARPE_NATIVE_GHOST=1 SCARPE_NATIVE_ARGS="--exit-after $SECS $*" "$(dirname "$0")/scarpe.sh" --native "$APP" 2>&1 | tail -3
ruby -rjson -e '
d=ARGV[0]; r=JSON.parse(File.read("#{d}/rust.json")); q=JSON.parse(File.read("#{d}/ruby.json"))
up=r["uptime"]; fr=r["frames"].size
puts "rust: #{fr} frames presented in #{up.round(2)}s; repainted_pixels/frame=#{(r["counters"]["repainted_pixels"].to_f/[fr,1].max).round}"
r["phases"].each{|k,v| puts "  rust #{k}: avg #{(v["total_ms"]/v["n"]).round(3)}ms max #{v["max_ms"]} n=#{v["n"]}"}
q["phases"].slice("timers","encode","flush","wait").each{|k,v| puts "  ruby #{k}: avg #{(v["total_ms"]/v["n"]).round(3)}ms max #{v["max_ms"].round(2)} n=#{v["n"]}"}
' "$D"
