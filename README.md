# AWDL Toggle

A small macOS menu bar app that turns off AWDL (`awdl0`) while you play a game in GeForce NOW
and turns it back on when the game ends. You can also flip it by hand from the menu bar.

## Why

AWDL (Apple Wireless Direct Link) is the peer-to-peer Wi-Fi link behind AirDrop, Sidecar,
Universal Control and peer-to-peer AirPlay. A Mac has one Wi-Fi radio, so while AWDL is active
the radio keeps stepping away from your access point's channel to talk to nearby Apple devices.
For browsing you never notice. For cloud gaming it shows up as regular latency spikes and lost
frames, on 2.4 GHz and 5 GHz alike.

Measured on a MacBook Pro (M1 Pro, macOS 26) over 5 GHz Wi-Fi, 900 pings to the access point
for each case:

|                              | AWDL on | AWDL off |
| ---------------------------- | ------: | -------: |
| Pings to the AP over 15 ms   |   14.7% |     0.1% |
| Average ping to the AP       | 10.3 ms |   2.5 ms |
| Internet ping p99 under load |  644 ms |    61 ms |
| Packet loss under load       |      5% |     0.5% |

With AWDL on, the link stalled for about 90 ms roughly every half second. In GeForce NOW, a
15-minute session with AWDL on ended with the client's own "lossy network" warning; a 58-minute
session with AWDL off logged one missed-frame event in about 207,000 frames.

Your numbers will depend on the Mac, the Wi-Fi and how many Apple devices are around.

## What it does

- Menu bar icon: radio waves while AWDL is on, a game controller while it is off.
- **Turn AWDL off / on**: manual switch.
- **Auto: off while playing GeForce NOW** (off by default): when a game stream starts, AWDL goes
  off. macOS sometimes brings it back up on its own; the app hears about that from the kernel at
  once and turns it off again, with a check every 3 seconds as a backup. When the stream ends, or
  the client quits or crashes, AWDL goes back on. Just opening the GeForce NOW client changes
  nothing; only an actual game does.
- Turning AWDL on by hand during a game keeps it on until that game ends.
- Every change is written to `~/Library/Logs/AWDLToggle.log`.

While AWDL is off, AirDrop, Sidecar, Universal Control and peer-to-peer AirPlay do not work.
Normal Wi-Fi is not affected.

The menu is in English, or in Russian when Russian is your first preferred language.

## Install

Needs the Xcode Command Line Tools (`xcode-select --install`). Tested on macOS 26 on Apple
Silicon.

```bash
git clone https://github.com/NickShtefan/awdl-toggle.git
cd awdl-toggle
./build.sh
cp -R "AWDL Toggle.app" ~/Applications/
open ~/Applications/"AWDL Toggle.app"
```

To start it at login, add it in System Settings > General > Login Items.

### Skip the password prompt

Bringing `awdl0` up or down needs root, so by default macOS asks for an admin password on every
switch. This sudoers rule allows exactly these two commands without a password:

```bash
echo "$(whoami) ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up" > /tmp/awdl-toggle.sudoers
visudo -cf /tmp/awdl-toggle.sudoers && sudo install -m 0440 -o root -g wheel /tmp/awdl-toggle.sudoers /etc/sudoers.d/awdl-toggle
```

To remove it:

```bash
sudo rm /etc/sudoers.d/awdl-toggle
```

## How the game is detected

The GeForce NOW client writes `geronimo.log` (rotated to `geronimo.log.bak`) in
`~/Library/Application Support/NVIDIA/GeForceNOW/`, with a `Streamer_Start` event when a game
stream begins and `Streamer_Exit` when it ends. The newer of the two tells the state. A crashed
client never logs `Streamer_Exit`, so the client (`com.nvidia.gfnpc.mall`) also has to be running.

This log format is not documented and may change with client updates. To check what the app
sees:

```bash
~/Applications/"AWDL Toggle.app"/Contents/MacOS/AWDLToggle --stream-state
```

It prints `streaming` or `idle`; `--status` prints whether AWDL is `up` or `down`, and `--watch`
prints `up` or `down` every time `awdl0` changes, until you press Ctrl+C.

## How AWDL is kept down

Changes to `awdl0` arrive on the kernel's routing socket (`PF_ROUTE`), which any user can read,
so the app learns about them without root and without polling. Bringing the interface down still
needs root, which goes through `sudo` and the rule above.

## Tests

```bash
./test.sh
```

Runs the app in a simulation mode (`AWDL_TEST_DIR`) where AWDL and the client are files in a
temporary folder, so the real interface is never touched. If the machine has GeForce NOW logs, it
also replays them.

## Without the app

```bash
sudo ifconfig awdl0 down
```

and `sudo ifconfig awdl0 up` to bring it back. A reboot also brings it back.

## Similar projects

- [awdlkiller](https://github.com/jamestut/awdlkiller): keeps AWDL down at all times; the
  routing-socket approach used here comes from it.
- [Stop Stutter](https://github.com/burakgon/stop-stutter): signed app with a privileged helper;
  holds AWDL off while a chosen client (GeForce NOW, Moonlight, Parsec, Steam Link and others)
  is open.
- [AWDL Control](https://github.com/james-howard/AWDLControl): holds AWDL off while the frontmost
  app is a game, like macOS Game Mode.
- [Ping Warden](https://github.com/oliverames/ping-warden): AWDL control with latency graphs and a
  Control Center toggle.
- [geforcenow-awdl0](https://github.com/sjparkinson/geforcenow-awdl0): holds AWDL off while
  GeForce NOW has a fullscreen window.

AWDL Toggle differs in reacting to the game stream itself rather than to the client being open
or in front, so AirDrop keeps working while you browse the GeForce NOW library.

The AWDL Control README also suggests putting the access point's 5 GHz band on channel 44 (EU) or
149 (US), the channels AWDL tends to use, so the radio has less reason to leave. That has not
been tested here.

## License

[MIT](LICENSE). Not affiliated with NVIDIA or Apple. GeForce NOW is a trademark of NVIDIA.
