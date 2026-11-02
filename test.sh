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

echo "--- transitions"
echo "$EXIT" > "$T/geronimo.log"; echo up > "$T/awdl"; touch "$T/gfn"
"$BIN" & PID=$!
sleep 4; check "client open, no game: stays on" up "$(state)"
echo "$START" >> "$T/geronimo.log"; sleep 4; check "game started: off" down "$(state)"
# Well under the 3 s tick, twice, so only the change watcher can pass these.
echo up > "$T/awdl"; sleep 0.5; check "macOS raised it during game: off within 0.5 s" down "$(state)"
echo up > "$T/awdl"; sleep 0.5; check "raised again: off within 0.5 s" down "$(state)"
echo "$EXIT" >> "$T/geronimo.log"; sleep 4; check "game ended, client still open: on" up "$(state)"
echo "$START" >> "$T/geronimo.log"; sleep 4; check "second game: off" down "$(state)"
rm "$T/gfn"; sleep 4; check "client crashed without Exit: on" up "$(state)"
touch "$T/gfn"; echo "$EXIT" >> "$T/geronimo.log"; echo down > "$T/awdl"; sleep 4; check "manual off outside game: stays off" down "$(state)"
check "journal: 2 stream starts" 2 "$(grep -c 'stream start' "$T/events.log")"
check "journal: 4 forced offs" 4 "$(grep -c 'turning off' "$T/events.log")"
check "journal: 2 of them from the watcher" 2 "$(grep -c 'came up during stream' "$T/events.log")"
kill $PID; rm -rf "$T"
echo "failures: $fails"
