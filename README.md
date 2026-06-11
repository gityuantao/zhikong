# 直控 ZhiKong

[![CI](https://github.com/gityuantao/zhikong/actions/workflows/ci.yml/badge.svg)](https://github.com/gityuantao/zhikong/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)

A low-latency, native macOS remote-desktop app: one Mac controls another over LAN or
the internet, with end-to-end encryption. Built from scratch with ScreenCaptureKit,
VideoToolbox (HEVC), and Network.framework — no third-party SDKs.

> **直控** = "direct control". Single app, two roles: **控制端 (Controller)** drives,
> **被控端 (Host)** shares its screen and accepts input.

---

## ⚠️ Status & honest disclaimers

- **Personal project, provided as-is.** No warranty, no support guarantees (MIT). It works
  well for the author's own use; it has not been hardened for hostile/multi-tenant deployment.
- **Uses private/undocumented Apple APIs** (low-level CoreGraphics event injection and the
  CGS gesture path used for Mission Control / Spaces swipes). As a result it will **not pass
  Mac App Store review** — it is intended for self-build or Developer-ID / notarized
  distribution only.
- **Remote control is powerful.** Only run the Host on machines you own and control. Treat the
  room code and shared secret like credentials.
- **Security is only as strong as your shared secret** — see [Security model](#security-model).
  There is no PAKE and no per-connection "allow this person?" prompt yet (the Host gates service
  behind an *"允许远程控制"* toggle). These are on the roadmap.

---

## Features

- **Native HEVC pipeline** — ScreenCaptureKit capture → VideoToolbox hardware HEVC encode →
  `AVSampleBufferDisplayLayer` decode/display with a rate-based jitter buffer.
- **LAN with zero config** — Bonjour auto-discovery, no server needed.
- **Internet via your own relay** — a tiny Python relay (`server/`) you host; the app ships
  with **no built-in relay address** (you point it at yours).
- **End-to-end encryption** — ChaCha20-Poly1305 (CryptoKit), HKDF-derived key, per-frame
  random nonce, direction-bound AAD. The relay only ever sees ciphertext and the room code.
- **Refreshable 6-char room code** — random, unambiguous alphabet (no `0/O/1/I/L`); regenerate
  on demand so the old code dies immediately.
- **Peer presence** — the relay reports whether the other end is online, so you get
  *"Host offline"* instead of a black screen.
- **Audio** — system audio captured via ScreenCaptureKit, AAC-compressed (~128 kbps).
- **Clipboard sync** — bidirectional plain-text, over the same encrypted channel.
- **Adaptive bitrate** (opt-in) — client reports received FPS; the Host runs a protective
  AIMD controller to back off under congestion.
- **Input passthrough** — mouse, keyboard, scroll, and Mission Control / Spaces gestures.
- **~72 unit tests** covering crypto, framing, codecs, layout, and config parsing.

## Screenshots

_Coming soon._ To add: drop PNGs into [`assets/screenshots/`](assets/screenshots/) and reference them here.

- `role-picker.png` — the launch role chooser (控制端 / 被控端)
- `host.png` — Host window showing the remote code + the *"允许远程控制"* toggle
- `session.png` — Controller viewing the remote screen

## How it works

```
                Controller (控制端)                       Host (被控端)
            ┌────────────────────────┐              ┌────────────────────────────┐
            │ decode + display       │   video/     │ ScreenCaptureKit capture    │
            │ (AVSampleBufferLayer)   │◀── audio ────│  → VideoToolbox HEVC encode │
            │                        │   (HEVC/AAC) │  → AAC audio                │
            │ capture input/gestures │── input ────▶│ inject via CGEvent          │
            │ clipboard ⇄            │   clipboard  │ clipboard ⇄                 │
            └───────────┬────────────┘              └──────────────┬──────────────┘
                        │       ChaCha20-Poly1305 (E2E)            │
                        └──────────────┬───────────────────────────┘
                       LAN (Bonjour)   │   or   WAN via your relay (opaque bytes)
                                  ┌─────┴─────┐
                                  │  relay    │  sees only: 4-byte length prefix,
                                  │ (Python)  │  room code, ciphertext. Cannot decrypt.
                                  └───────────┘
```

All streams share one length-prefixed connection and are demuxed by a 4-byte magic:
`ZKV1` video · `ZKA1` audio · `ZKC1` clipboard · `ZKFB` fps feedback · `ZKRL` relay presence.

## Requirements

- **macOS 14 (Sonoma) or later**, Apple Silicon recommended.
- **Xcode 15+** (macOS 14 SDK).
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`.

## Build & run

```sh
xcodegen generate
xcodebuild -project ZhiKong.xcodeproj -scheme ZhiKong \
           -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/ZhiKong.app
```

> **Signing:** `project.yml` uses manual signing with a local self-signed identity named
> `ZhiKong Dev`. Either create that identity in Keychain Access, or edit `project.yml` to use
> `CODE_SIGN_STYLE: Automatic` with your own team (or ad-hoc signing) before building.

Launch the app and pick a role, or skip the picker with an env var:

```sh
ZHIKONG_ROLE=host   open -n build/Build/Products/Debug/ZhiKong.app   # run as Host
ZHIKONG_ROLE=client open -n build/Build/Products/Debug/ZhiKong.app   # run as Controller
```

**Permissions** (Host machine, granted on first run via System Settings, then restart the app):
*Screen Recording*, *Accessibility* (input injection), and *Automation → System Events*
(Mission Control / Spaces gestures).

## LAN vs. internet (relay)

- **LAN:** nothing to configure. Both Macs on the same network discover each other via Bonjour.
- **Internet:** run the relay on a server both machines can reach, then point the app at it.

```sh
# on your server
python3 server/zkrelay.py 7777
# (or install server/zkrelay.service as a systemd unit for auto-start)
```

Then on **both** Macs, either set env vars or create `~/.zhikong/relay.conf`
(see [`server/relay.conf.example`](server/relay.conf.example)):

```
your-relay-host:7777  a-long-random-shared-secret
```

## Configuration (environment variables)

| Variable | Meaning |
|---|---|
| `ZHIKONG_ROLE` | `host` or `client` — skip the role picker |
| `ZHIKONG_LAN` | `1` — force LAN (Bonjour), ignore any relay config |
| `ZHIKONG_RELAY` | `host:port` — relay address (unset ⇒ LAN) |
| `ZHIKONG_SECRET` | end-to-end shared secret (**never sent to the relay**) |
| `ZHIKONG_ROOM` | fixed room code (testing; default is dynamic) |
| `ZHIKONG_ADAPTIVE` | `1` — enable adaptive bitrate |
| `ZHIKONG_WAN_BITRATE` / `..._MAXDIM` / `..._KEYFRAME` / `..._BITRATE_MAX` | encoder tuning for WAN |
| `ZHIKONG_AUDIO_PCM` | `1` — disable AAC, send uncompressed audio |

Precedence: env vars > `~/.zhikong/relay.conf` > LAN default.

## Security model

- Traffic is encrypted end-to-end with **ChaCha20-Poly1305**; the key is derived via
  **HKDF-SHA256** from a shared secret, with direction-bound AAD to prevent reflection.
- The relay is **untrusted by design**: it forwards opaque ciphertext and only sees the cleartext
  length prefix and the room code. It cannot read or modify your session content.
- **Set a strong `ZHIKONG_SECRET`.** If you don't, the key falls back to one derived from the
  short 6-character room code — anyone who can observe the pairing handshake can then derive the
  key. The app logs a warning in this fallback mode. This is *not* real E2E security; it exists
  only as a zero-config convenience.
- **Not yet implemented:** PAKE (so a short code is safe even against the relay operator), and a
  per-connection confirmation prompt on the Host. Until then, the Host's *"允许远程控制"* toggle is
  the gate — keep it off when you're not expecting a connection.

## Project layout

```
Sources/App      entry point + role picker
Sources/Host     capture, HEVC encode, audio, input injection, server
Sources/Client   connection, decode/display, input & gesture capture
Sources/Shared   wire protocol, crypto, codecs, RelayConfig/RoomCode
Tests            unit tests
server           zkrelay.py (asyncio relay) + systemd unit + relay.conf.example
project.yml      XcodeGen project definition
```

## Tests

```sh
xcodebuild test -project ZhiKong.xcodeproj -scheme ZhiKong -destination 'platform=macOS'
```

## License

[MIT](LICENSE) © 2026 White.

---

## 中文简介

**直控** 是一个原生 macOS 远程桌面 app:用一台 Mac 远程控制另一台,局域网与外网都可用,端到端加密。
全程自研(ScreenCaptureKit 采集 + VideoToolbox HEVC 硬编 + Network.framework 传输),不依赖任何第三方 SDK。

单 app、启动选角色:**控制端**操控、**被控端**共享屏幕并接受输入。局域网零配置(Bonjour 自动发现);
外网需要你**自建**一台中转(见 `server/`),app 不内置任何中转地址。加密口令(`ZHIKONG_SECRET` / `relay.conf`)
**绝不发给中转**,中转只能看到密文与房间码。

> 注意:本项目使用了部分私有/未公开的 Apple API(手势注入等),**大概率无法上架 Mac App Store**,适合自行编译或
> 开发者 ID 公证分发;且属个人项目,按现状提供、不作担保。务必只在你自己拥有控制权的机器上运行被控端。
