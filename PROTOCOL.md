# Screenlet protocol, version 1

The link between a **computer** (Screenlet for macOS, GNOME, later Windows
and KDE) and the **app** (Screenlet companion for Android). It is Plus One's
protocol 3 renamed and tightened for latency. The two do not interoperate.
MUST, SHOULD and MAY are used as in RFC 2119. Integers are big-endian
unless marked `le`. `‖` is concatenation and `hex()` is lowercase hex.

The app is the server (it listens). The computer is the client.

The same file is in every Screenlet repository, with `vectors.json`, which
each implementation's tests check.

## Constants

| Name | Value |
|---|---|
| Protocol version | `1` |
| Bonjour service | `_screenlet._tcp` |
| TCP port | `47237` (the app MAY use another and announce it) |
| Max message, before pairing | 4096 bytes |
| Max message, after pairing | 64 KiB |
| App drops a silent paired computer after | 90 s |
| Computer pings during a display session | every 5 s |
| Video bytes per packet | exactly 1426, except a frame's last packet |
| Input repeat interval (app) | 0.1 s |
| Input silence timeout (computer) | 0.4 s, then everything is lifted |
| Cable: app read size | 16 KiB |
| Cable: computer max write | 48 KiB |
| Wi-Fi Direct group owner address | `192.168.49.1` |

## 0. Paths

The computer picks the path by itself, in this order, and the user never chooses:

1. **Cable** (§4), whenever a tablet is plugged in.
2. **Network**: a paired tablet announced with Bonjour.
3. **Wi-Fi Direct**: when neither of the above, the tablet runs a Wi-Fi
   Direct group of its own. A computer that learned the group's credentials
   (§2.1) MAY join it as an ordinary Wi-Fi network and connect to the
   group owner address. The app starts the group only while it is on no
   Wi-Fi network and has no cable, because the group's radio time slows
   other Wi-Fi traffic.

## 1. Discovery

The app MUST announce `_screenlet._tcp` with these TXT records:

| Key | Value |
|---|---|
| `id` | the first 16 hex digits of the app certificate's fingerprint |
| `name` | the tablet's name |

If `id` matches a paired tablet, the computer MUST require that tablet's
certificate.

## 2. Link

- TLS 1.3. Each side presents a self-signed EC P-256 certificate. There is no CA.
- **Fingerprint** = `hex(SHA-256(certificate DER))`.
- The computer accepts the app's certificate only if it is paired, or after pairing (§2.2).
- **Framing**, both ways: `length u32 ‖ JSON object (length bytes, UTF-8)`.
  A receiver MUST close the link on a message over the size limit.

### 2.1 Hello

The computer sends first and the app replies:

```json
{"type": "hello", "name": "Davide's Mac", "version": 1, "paired": true, "pair": false}
{"type": "hello", "name": "Galaxy Tab S9", "version": 1, "paired": true, "at": "192.168.0.204",
 "p2p": {"ssid": "DIRECT-xy-Screenlet", "passphrase": "…", "at": "192.168.49.1"}}
```

| Field | From | Meaning |
|---|---|---|
| `name` | both | name to show |
| `version` | both | MUST be `1`; on a mismatch both sides close |
| `paired` | both | this side knows the other's certificate |
| `pair` | computer | the user asked to pair with this tablet |
| `at` | app | the app's address as the computer reached it |
| `p2p` | app | its Wi-Fi Direct group. Sent only when both sides are paired. The computer stores it with the pairing |

### 2.2 Pairing

Pairing runs if either `paired` is false and the computer sent `"pair": true`.
Otherwise an unpaired link MUST be closed.

| Step | Sender | Message |
|---|---|---|
| 1 | app | `{"type": "pair-commit", "commit": hex(SHA-256(appNonce ‖ appCertDER ‖ computerCertDER))}` |
| 2 | computer | `{"type": "pair-nonce", "nonce": hex(computerNonce)}` |
| 3 | app | `{"type": "pair-nonce", "nonce": hex(appNonce)}` |
| 4 | computer | checks the commitment from step 1; on a mismatch it closes |
| 5 | both | show the code |
| 6 | both | `{"type": "pair-ok"}` or `{"type": "pair-no"}`, after the user answers |

- Nonces are 16 random bytes.
- **Code** = `uint32(SHA-256(lo ‖ hi ‖ computerNonce ‖ appNonce)[0..4]) mod 1000000`,
  zero-padded to 6 digits. `lo` and `hi` are the two certificate DERs in bytewise order.
- If both sides send `pair-ok`, each stores the other's certificate.

### 2.3 Other messages

| Message | Meaning |
|---|---|
| `{"type": "ping"}` → `{"type": "pong"}` | keepalive |
| `{"type": "bye"}` | close the link |

## 3. Display session

The computer requests it on a paired link:

```json
{"type": "display", "key": "<64 hex: AES-256 key>", "port": 50123, "codec": "hevc"}
```

The app replies with one of:

```json
{"type": "display-ready", "port": 41089, "width": 2560, "height": 1600, "refresh": 120.0, "codec": "hevc"}
{"type": "refused", "reason": "background" | "unavailable"}
```

| Field | Rule |
|---|---|
| `key` | a fresh random AES-256 key for each session |
| `port` | the sender's UDP port; ignored over the cable |
| `width`, `height` | the tablet's panel in pixels, landscape |
| `refresh` | the fastest refresh rate the panel runs at during the session. The computer SHOULD capture at that rate, capped at what it can sustain |
| `codec` | request: `"avc"` (the default) or `"hevc"`. The reply is what the app will decode: `"avc"` without hardware HEVC. The computer MUST encode the replied codec |

After `display-ready` the computer extends to a new display at the tablet's
proportions, or mirrors one of its displays (letterboxed by the app), and
streams it. The link stays open. The computer pings every 5 s and sends
`{"type": "stop"}` to end. Closing the link also ends the session.

### 3.1 Packet envelope

Each packet is a UDP datagram, or a cable DATAGRAM frame, sealed with
AES-GCM under the session key:

```
nonce[12] = direction u32 ‖ count u64
datagram  = nonce ‖ ciphertext ‖ tag[16]
```

- `direction` is `1` from the computer to the app and `2` from the app to the computer.
- `count` starts at 0 in each direction and goes up by 1 for each packet.
- A receiver MUST drop a packet that fails authentication. It MUST also
  drop one whose `count` it already accepted, or that is 64 or more below
  the highest accepted. A small window, not strictly increasing: Wi-Fi
  reorders.
- The plaintext starts with `kind u8`.

### 3.2 Packet kinds

| Kind | Name | Direction | Body after `kind` | Size |
|---|---|---|---|---|
| 1 | VIDEO | computer → app | `flags u8` (bit 0 = keyframe), `frame u32`, `index u16`, `count u16`, `captured i64`, video bytes | 17 + ≤1426 |
| 2 | KEYFRAME | app → computer | none | 0 |
| 3 | PING | app → computer | `time i64`, `shown u8` | 9 |
| 4 | PONG | computer → app | `pingTime i64`, `computerTime i64` | 16 |
| 5 | STATS | app → computer | `shown u32`, `lost u32`, then 5 stages × (median, p90, max) as `u16` in 0.1 ms units (§3.5) | 38 |
| 6 | INPUT | app → computer | `fingers u8`, per finger `id u8, x u16, y u16`; `samples u8`, per sample 9 bytes (§3.4) | variable |

Receivers MUST ignore unknown kinds and bodies that are too short.

### 3.3 Video

- Codec: H.264 (High or Constrained High) or HEVC Main, in Annex B with
  start codes. No B-frames. No more than one reference frame is needed.
- A keyframe MUST carry its parameter sets (SPS and PPS, plus VPS for HEVC).
- The colour MUST be signalled in the VUI: BT.709 primaries, transfer and
  matrix. Range: full or limited, as signalled.
- Each frame is split into `count` packets numbered from `index` 0. Every
  packet except the last carries exactly 1426 bytes, so the app copies each
  one straight to `index × 1426` in the frame.
- `captured` is the computer's monotonic clock in ns at capture.
- The app decodes a frame as soon as all its packets have arrived and shows
  it at the next vsync, with no jitter buffer. When a frame is complete,
  older incomplete frames are lost. The app then sends KEYFRAME, again at
  most every 0.25 s, until a keyframe arrives.
- While PING's `shown` is 0 the computer SHOULD stop capturing. When it
  returns to 1 the computer MUST send a keyframe.

### 3.4 Input

- Each INPUT is the whole current state. The app sends one at every
  touch or pen event, as the digitizer reports it, and repeats the state
  every 0.1 s while anything touches.
- A finger in the previous INPUT that is missing now has lifted. After no
  INPUT for 0.4 s the computer lifts everything.
- Finger `x` and `y` run 0–65535 across the screen.
- A pen sample is the S Pen HID report without its report ID, all `le`:

| Offset | Field | Type | Range |
|---|---|---|---|
| 0 | bits | u8 | `0x01` tip, `0x02` barrel button, `0x08` eraser, `0x10` in range |
| 1 | x | u16 le | 0–32767 |
| 3 | y | u16 le | 0–32767 |
| 5 | pressure | u16 le | 0–4096 |
| 7 | tilt x | s8 | degrees |
| 8 | tilt y | s8 | degrees |

The computer MUST reject an INPUT that is truncated or lists more than 10 fingers.

### 3.5 Latency, measured stage by stage

The app aligns the clocks with PING and PONG. It keeps the offset from the
ping with the shortest round trip; the offset ages out after 10 s. Once a
second it sends STATS for the frames shown in that second:

| Stage | From → to | What it shows |
|---|---|---|
| 0 | capture → decoded | the whole way (clocks aligned) |
| 1 | capture → first packet | the computer's capture, encode and send, plus the network (clocks aligned) |
| 2 | first → last packet | how long the frame took to arrive |
| 3 | last packet → queued | waiting for a decoder input buffer |
| 4 | queued → decoded | the decoder |

The computer measures its own stages: capture → encoded → sent. Together
these say where each millisecond goes.

## 4. Cable (Android Open Accessory)

USB-C, with no tethering and no developer options. The computer is the USB host.

1. The computer sends the AOA control requests 51 (get protocol), 52 (send
   strings) and 53 (start), with manufacturer `Screenlet`, model `Screenlet`,
   description `Screenlet on the computer` and version `1`.
2. The tablet re-enumerates as an accessory (Google VID `0x18D1`, PID
   `0x2D00` or `0x2D01`), asks its user once, and opens the app.
3. One bulk endpoint in each direction carries frames:

```
frame = kind u8 ‖ connection u8 ‖ length u32 ‖ data[length]
```

| Kind | Name | Meaning |
|---|---|---|
| 0 | HELLO | from the computer: reset and close all connections. The app replies with HELLO. The computer repeats HELLO until it gets a reply |
| 1 | OPEN | a new TLS connection, number `connection` |
| 2 | DATA | bytes for `connection` |
| 3 | CLOSE | `connection` ended |
| 4 | DATAGRAM | one §3.1 datagram, either direction |

- TLS, pairing and AES-GCM run end to end inside the frames. The cable is not trusted.
- The app reads in 16 KiB transfers. The computer writes at most 48 KiB per
  transfer. A transfer that is an exact multiple of the endpoint's max
  packet size MUST be followed by a zero-length packet.
- A frame may span several transfers, so receivers MUST buffer until all `length` bytes have arrived.
- The computer SHOULD batch the datagrams of one video frame into as few
  transfers as fit, and SHOULD NOT let a TLS DATA frame delay them.
