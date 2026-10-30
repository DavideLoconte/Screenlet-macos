<p align="center"><img src="docs/icon.png" width="128" alt="Screenlet icon"></p>

<h1 align="center">Screenlet for macOS</h1>

<p align="center">Your Android tablet as a second display for your Mac,<br>
with touch and pen, over a USB-C cable first and Wi-Fi when there is none.</p>

---

This is the Mac's half of Screenlet. On the tablet, install
[Screenlet companion](https://github.com/DavideLoconte/Screenlet-companion).
[Screenlet for GNOME](https://github.com/DavideLoconte/Screenlet-gnome) is the
Linux half. Windows and KDE will follow.

## Use it

1. Install Screenlet on the Mac and the companion on the tablet.
2. Plug the tablet in with a USB-C cable, or have it on the same Wi-Fi.
3. Click **Pair** in Screenlet's menu bar item and check that both screens
   show the same six digits.

That is all. From then on, plugging the tablet in shows the desktop on it,
and **Disconnect** in the menu bar ends it. The window has only three
settings: **Extend** or **Mirror**, the resolution (Automatic by default),
and the priority (Latency, Balanced or Clarity). The refresh rate follows the
tablet's panel, up to 120 Hz. The codec is HEVC where the tablet decodes it
in hardware and H.264 otherwise. The cable is always used when it is plugged in.

- **Fingers**: a finger moves the pointer the moment it lands. It clicks
  when it lifts, drags as soon as it moves, and presses after being held
  still for a moment. Two fingers scroll, and a two-finger tap is a right click.
- **Pen**: proximity, pressure and tilt reach the apps that read a tablet.
  The button is a right click.

## Install

Download `Screenlet-<version>-macos.zip` from [Releases](../../releases) and
move `Screenlet.app` to Applications. It is signed ad hoc, not with a
Developer ID, so remove the quarantine flag before the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Screenlet.app
```

On first launch Screenlet asks for **Screen Recording** and **Accessibility**
(for touch and pen), and macOS asks about the **local network**. It needs
macOS 15. The log is at `~/Library/Logs/Screenlet.log`.

## Latency

- **Capture**: ScreenCaptureKit at the tablet's refresh rate, on a virtual
  display that refreshes at the same rate.
- **Encode**: the hardware encoder with low-latency rate control, speed
  before quality, no frame reordering, and no frame held back. BT.709 colour
  is declared in the stream, so the tablet shows the Mac's colours.
- **Annex B**: copied once from the encoder's memory.
- **Send**: from a thread of its own, so a slow USB write never holds the
  encoder. Each frame's packets go in as few USB transfers as fit, built in
  one buffer.
- **Wi-Fi**: the send queue holds about one keyframe, no more. The bitrate
  starts at half and adapts every second from the delay the tablet measures.
- **Touch**: nothing waits to see whether a second finger is coming.

Every two seconds the log shows the median of each stage of a frame's way:
encoded and sent on the Mac, then first packet, spread, decoder wait and
decode on the tablet. The stages are defined in [PROTOCOL.md](PROTOCOL.md) §3.5.

```bash
/Applications/Screenlet.app/Contents/MacOS/Screenlet --show-cable 20 pattern measure   # or --show-wifi
./bench.sh cable    # every codec × priority: latency, fps, kbit/s and PSNR fidelity
```

## Build

macOS 15 and Xcode 16:

```bash
swift test
./build-app.sh      # dist/Screenlet.app, its zip and a Homebrew cask
```

CI tests and builds every push. A `v*` tag publishes a release.

## License

MIT. Screenlet started as a fork of
[Plus One](https://github.com/GabrieleSantangelo/PlusOne) by Gabriele Santangelo.
