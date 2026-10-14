#!/bin/sh
# Keep kwg running on the Kindle: wait for Wi-Fi, start the tunnel, restart it
# when it exits, when Wi-Fi drops, or when the default gateway changes
# (other network). Started at boot by the upstart job (kwg.upstart).
# usage: kwg-loop.sh [config] [log]   (defaults: wg.conf / kwg.log next to this script)
DIR=$(cd "$(dirname "$0")" && pwd)
BIN=$DIR/kwg
CONF=${1:-$DIR/wg.conf}
LOG=${2:-$DIR/kwg.log}

gw() { ip route | awk '/^default/ {print $3; exit}'; }

while true; do
  G=$(gw)
  if [ -z "$G" ]; then
    sleep 10
    continue
  fi
  # keep the log small
  [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  echo "$(date '+%F %T') starting kwg (gateway $G)" >> "$LOG"
  "$BIN" up "$CONF" >> "$LOG" 2>&1 &
  PID=$!
  while kill -0 "$PID" 2>/dev/null; do
    sleep 15
    if [ "$(gw)" != "$G" ]; then
      echo "$(date '+%F %T') network changed, restarting" >> "$LOG"
      kill "$PID"
      break
    fi
  done
  wait "$PID" 2>/dev/null
  sleep 5
done
