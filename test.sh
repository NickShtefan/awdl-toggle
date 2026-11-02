#!/bin/zsh
# Simulated run: AWDL and the client are files in a temp dir, the real interface is not touched.
cd "$(dirname "$0")"
BIN="$PWD/AWDL Toggle.app/Contents/MacOS/AWDLToggle"
[ -x "$BIN" ] || ./build.sh
REAL="$HOME/Library/Application Support/NVIDIA/GeForceNOW"
T=$(mktemp -d)
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected $2, got $3"; fails=$((fails+1)); fi; }
state() { cat "$T/awdl"; }
START='[x] {"name": "Streamer_Start", "parameters" : {}}'
EXIT='[x] {"name": "Streamer_Exit", "parameters" : {}}'

echo "--- log parsing"
export AWDL_TEST_DIR="$T"
# Replays this machine's real client logs, if there are any.
cat "$REAL/geronimo.log.bak" "$REAL/geronimo.log" 2>/dev/null > "$T/all.log"
n=$(grep -an '"name": "Streamer_Start"' "$T/all.log" | tail -1 | cut -d: -f1)
# The client rotates its logs on launch, so a freshly opened one may have no stream events yet.
if [ -n "$n" ]; then
  head -n "$n" "$T/all.log" > "$T/geronimo.log"
  check "real log cut at last Start" streaming "$("$BIN" --stream-state)"
  cp "$T/all.log" "$T/geronimo.log"; echo "$EXIT" >> "$T/geronimo.log"
  check "real log plus Exit" idle "$("$BIN" --stream-state)"
else
  echo "skip  real logs: no GeForce NOW stream events on this machine"
fi
echo "no events" > "$T/geronimo.log"; echo "$START" > "$T/geronimo.log.bak"
check "rotated: Start only in .bak" streaming "$("$BIN" --stream-state)"
rm -f "$T/geronimo.log.bak"; check "no events anywhere" idle "$("$BIN" --stream-state)"

echo "--- routing messages"
# A build without --self-test would start the app instead, so it gets 10 s.
check "awdl0 change filter" ok "$(perl -e 'alarm 10; exec @ARGV' "$BIN" --self-test | tail -1)"

echo "--- transitions"
echo "$EXIT" > "$T/geronimo.log"; echo up > "$T/awdl"; touch "$T/gfn"
"$BIN" & PID=$!
sleep 4; check "client open, no game: stays on" up "$(state)"
echo "$START" >> "$T/geronimo.log"; sleep 4; check "game started: off" down "$(state)"
# Well under the 3 s tick, twice, so only the change watcher can pass these.
echo up > "$T/awdl"; sleep 0.5; check "macOS raised it during game: off within 0.5 s" down "$(state)"
sleep 0.3; echo up > "$T/awdl"; sleep 0.5; check "raised again: off within 0.5 s" down "$(state)"
echo "$EXIT" >> "$T/geronimo.log"; sleep 4; check "game ended, client still open: on" up "$(state)"
echo "$START" >> "$T/geronimo.log"; sleep 4; check "second game: off" down "$(state)"
rm "$T/gfn"; sleep 4; check "client crashed without Exit: on" up "$(state)"
touch "$T/gfn"; echo "$EXIT" >> "$T/geronimo.log"; echo down > "$T/awdl"; sleep 4; check "manual off outside game: stays off" down "$(state)"
check "journal: 2 stream starts" 2 "$(grep -c 'stream start' "$T/events.log")"
check "journal: 4 forced offs" 4 "$(grep -c 'turning off' "$T/events.log")"
check "journal: 2 of them from the watcher" 2 "$(grep -c 'came up during stream' "$T/events.log")"
kill $PID; rm -rf "$T"

echo "--- macOS keeps raising it"
F=$(mktemp -d)
echo "$START" > "$F/geronimo.log"; echo up > "$F/awdl"; touch "$F/gfn"
head -c 1100000 /dev/zero > "$F/events.log"
# A fake macOS that raises AWDL again as soon as it goes down.
( while :; do [ "$(cat "$F/awdl")" = down ] && echo up > "$F/awdl"; sleep 0.02; done ) & FIGHTER=$!
AWDL_TEST_DIR="$F" "$BIN" & PID=$!
sleep 6
offs=$(grep -c 'turning off' "$F/events.log")
check "2 offs/s, then one per 3 s (9-13 in 6 s)" yes "$([ "$offs" -ge 9 ] && [ "$offs" -le 13 ] && echo yes || echo "no, $offs")"
check "slowdown logged once" 1 "$(grep -c 'keeps coming back' "$F/events.log")"
echo "$EXIT" >> "$F/geronimo.log"; sleep 4
check "game end noticed during the fight" 1 "$(grep -c 'stream end' "$F/events.log")"
kill $FIGHTER; sleep 1; check "on after the game" up "$(cat "$F/awdl")"
check "full journal moved aside" yes "$([ -f "$F/events.log.1" ] && [ "$(wc -c < "$F/events.log")" -lt 100000 ] && echo yes || echo no)"
kill $PID; rm -rf "$F"

echo "--- switch fails"
X=$(mktemp -d)
echo "$START" > "$X/geronimo.log"; echo up > "$X/awdl"; touch "$X/gfn"; chmod 444 "$X/awdl"
AWDL_TEST_DIR="$X" "$BIN" & PID=$!
sleep 4
check "one failed attempt, no retries" 1 "$(grep -c 'set down: failed' "$X/events.log")"
check "left on" up "$(cat "$X/awdl")"
kill $PID; rm -rf "$X"

echo "--- nothing to watch"
N=$(mktemp -d)
AWDL_TEST_DIR="$N" "$BIN" & PID=$!
sleep 1
check "falls back to the 3 s check" 1 "$(grep -c 'watcher unavailable' "$N/events.log")"
kill $PID; rm -rf "$N"
echo "failures: $fails"
