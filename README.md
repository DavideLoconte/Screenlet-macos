<p align="center"><img src="docs/icon.png" width="128" alt="Screenlet icon"></p>

# Screenlet for macOS

*Screenlet for macOS* turns an Android tablet (specifically optimized for Samsung Galaxy Tab devices and the S Pen) into an ultra-low-latency secondary display for macOS over Wi-Fi or a USB-C connection. The tablet client runs [Screenlet Companion](https://github.com/DavideLoconte/Screenlet-companion), communicating via the [Screenlet protocol](PROTOCOL.md).

The application is implemented natively in Swift with minimal Objective-C bridging components and maintains zero external dependencies. Screenlet originated as a fork of [Plus One](https://github.com/GabrieleSantangelo/PlusOne).

> [!NOTE]
> The current version is in development and prone to changes. The version number is specified in [VERSION](VERSION).

Alternative desktop host implementations include [Screenlet for GNOME](https://github.com/DavideLoconte/Screenlet-linux) and [Screenlet for Windows](https://github.com/DavideLoconte/Screenlet-windows).

## Features

- **Ultra-low latency.** Achieves approximately 19 ms median latency from screen capture to hardware decode over a USB connection using hardware-accelerated H.264 or HEVC, bypassing intermediate jitter buffers.
- **Extend or Mirror modes.** Creates a virtual display matching the tablet's native aspect ratio (automatic, native, or custom resolution) refreshing at up to 120 Hz, or mirrors an existing Mac display.
- **Touch and S Pen translation.** Touch input translates directly into macOS pointer events: single-finger contact moves the pointer and triggers clicks or drags; two-finger gestures handle scrolling and right-click taps; stylus input forwards proximity, pressure, and tilt data.
- **Streamlined connection management.** One-click connection handles initial pairing and immediately launches the display session. Supports optional automatic connection upon connecting a paired tablet via USB. If multiple tablets are connected, each device is managed independently.
- **Flexible transport (USB or Network).** USB connections utilize the Android Open Accessory protocol without requiring developer options on the tablet. Over Wi-Fi, tablets are discovered automatically using Bonjour.
- **Comprehensive configuration.** The application window offers intuitive resolution and optimization presets (Lowest Latency, Balanced, or Sharpest), while the Advanced tab exposes fine-grained control over codec selection, refresh rate, bitrate, maximum frame size, packetization, and keyframe intervals, alongside live latency diagnostics.
- **Authenticated security.** Mutual authentication is verified via a six-digit code displayed on both devices. The control channel is secured using TLS 1.3, and video and input datagrams are encrypted end-to-end with AES-GCM.

## Latency Optimizations

- VideoToolbox hardware encoding is configured for low-latency rate control, prioritizing encoding speed over compression efficiency with zero frame reordering and explicit BT.709 color tagging. Encoded Annex B bitstreams are transferred directly from encoder memory.
- Packet dispatch runs on a dedicated high-priority worker thread, ensuring that USB write throughput variations do not stall the video encoder pipeline.
- Network send queues are bounded to approximately one keyframe. Bitrate initializes conservatively and dynamically adapts every second based on round-trip latency reported by the tablet.
- Touch input is dispatched instantaneously without delay windows for multi-touch classification.

Running `--show-cable` or `--show-wifi` outputs real-time median latency metrics every two seconds: host capture, encoding, and transmission time, followed by client packet transit, decoder queue delay, and hardware decode duration ([PROTOCOL.md](PROTOCOL.md) §3.5). The `measure` option evaluates video fidelity (luma PSNR of the encoded stream), and `./bench.sh` benchmarks various codec and priority profiles against synthetic test patterns.

## Architecture

| Component | Implementation Details |
|---|---|
| Virtual display | `CGVirtualDisplay`: CoreGraphics private API for runtime display creation |
| Capture and encoding | ScreenCaptureKit (NV12 format) and VideoToolbox (H.264 or HEVC with low-latency rate control) |
| Bandwidth adaptation | Dynamic bitrate control adjusted every second from client telemetry |
| Control link and discovery | Network.framework with TLS 1.3; Bonjour discovery via `NWBrowser` |
| Video datagrams | CryptoKit AES-GCM encryption dispatched over UDP or USB |
| USB transport | Android Open Accessory protocol implemented directly via IOUSBHost |
| Input synthesis | `CGEvent` generation for pointer and tablet events |
| User interface | Menu bar item, SwiftUI main window, and initial permission assistant |

Because VideoToolbox only provides hardware acceleration for H.264 and HEVC, other codecs are not supported.

## Building and Installation

### Requirements

- macOS 15 or later.
- Xcode 16 or later.

### Compilation

```bash
swift test
./build-app.sh       # Produces dist/Screenlet.app, a distribution archive, and a Homebrew cask
```

### Installation via Homebrew

Create a local tap and install the generated cask:

```bash
brew tap-new <user>/screenlet
cp dist/screenlet.rb $(brew --repository <user>/screenlet)/Casks/
brew install --cask <user>/screenlet/screenlet
```

Because the application is signed ad-hoc, remove the quarantine attribute before launching:

```bash
xattr -dr com.apple.quarantine "/Applications/Screenlet.app"
```

### Initial Configuration

On initial launch, Screenlet requires **Screen Recording**, **Accessibility**, and **Local Network** permissions granted in System Settings. Application logs are written to `~/Library/Logs/Screenlet.log`.

Continuous integration validates tests and builds on every commit. Tagging a release (`v*`) automatically publishes release archives and cask definitions.

## Latency Benchmarks

```bash
"/Applications/Screenlet.app/Contents/MacOS/Screenlet" --show-cable 20 [pattern | mirror | hevc | latency | balanced | clarity | 30 | native | WxH]
```

This command streams the desktop over USB for 20 seconds, logging synchronized end-to-end latency metrics every 2 seconds. The `--show-wifi 20` argument performs the equivalent test over the local network. The `pattern` argument generates a deterministic moving test pattern (scrolling text, panning imagery, and synthetic gradients) to ensure consistent benchmark comparisons.

Measured on a Samsung Galaxy Tab S6 Lite using H.264 and the Latency optimization profile against the release build of Screenlet Companion:

| Transport Interface | Median Latency (Capture to Decode) | 90th Percentile Latency |
|---|---|---|
| USB Cable | 11–12 ms | 17 ms |
| Wi-Fi 5 GHz (AWDL disabled) | 13–14 ms | 18–19 ms |

Of the total latency, approximately 2–3 ms are spent in host capture and encoding, under 1 ms in network transit, and 6–7 ms in client hardware decoding.

> [!TIP]
> On macOS, Apple Wireless Direct Link (AWDL)—utilized by AirDrop, Handoff, and Sidecar—periodically causes Wi-Fi channel hops, introducing transient packet transmission spikes. Disabling AWDL via `sudo ifconfig awdl0 down` reduces 90th percentile latency significantly (from ~95 ms down to 30–45 ms on reference test hardware). AWDL can be re-enabled using `sudo ifconfig awdl0 up`.

## Roadmap

- Multi-device validation: Complete testing across multi-tablet USB configurations, accessory enumeration, and interface selection in IOUSBHost.
- HiDPI scaling: Implement adaptive display scaling based on client physical pixel density rather than static thresholding.
- Scaled UI modes: Provide intermediate fractional scaling options between 1x and 2x.
- CoreGraphics compatibility: Implement automated fallback to standard DPI if private `CGVirtualDisplay` flags are deprecated in future macOS releases.
- Wi-Fi Direct: Implement client connection handling for tablet-hosted P2P networks.

## License

Distributed under the [MIT License](LICENSE), matching the upstream Plus One project.

## AI Disclosure

Much of this codebase was generated with the assistance of Anthropic's Claude model through Claude Code, under direct human architectural guidance, specification, and hardware verification.
