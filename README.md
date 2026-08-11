# ZeroSound

ZeroSound turns nearby Macs into one synchronized office speaker room. Open the menu-bar item or
main window, click a visible room (or **Create Office Room**), and the Mac joins immediately as an
active speaker. Any room member can choose **Play from this Mac** without dismantling the room.

## Product model

- Every connected computer is an equal room member.
- One internal coordinator maintains the roster and room timeline; it is not a user role.
- Zero or one member is the current audio source.
- The room remains when its source leaves and elects a replacement when its coordinator leaves.
- The source name and live level are shared. Exact browser or music-track metadata is intentionally
  out of scope.

The app captures system audio (including YouTube and other browser audio) using the public Core
Audio process-tap APIs available on macOS 14.2 and later. Audio is sent as numbered 5 ms stereo PCM
packets against a shared room timeline. A disciplined offset-and-skew clock, 300 ms presentation
lead, bounded reorder window, loss concealment, measured Core Audio playhead phase, output-latency
compensation, and automatic renderer recovery keep the room stable on normal office Wi-Fi.

## Run it

Build and launch locally:

```bash
swift run ZeroSound
```

Or build the distributable macOS app and AirDrop archive:

```bash
./Scripts/build-app.sh
```

The build script creates a universal Apple-silicon/Intel app and zip archive under `.build/`. Without
a Developer ID certificate it uses ad-hoc signing, so a friend may need to Control-click **Open** on
first launch. Every Mac in a room must use the current room protocol; incompatible rooms remain
visible but show **Update required** instead of allowing a broken join.

Direct builds use Sparkle 2 for EdDSA-verified over-the-air updates. Ad-hoc updating works in local
release tests, but a fresh Mac can still apply Gatekeeper policy because Apple does not identify the
app. See [`docs/updates.md`](docs/updates.md) for the trust model and release procedure.

On first use, allow local-network access on every Mac. The Mac chosen as the audio source also needs
system-audio recording permission. Closing the main window does not leave the room; the menu-bar
remote remains active.

## Architecture

`ZeroSoundAudioIO` contains only the Core Audio callback and lock-free capture ring.
`ZeroSoundCore` is divided into pure room domain state, discovery/transport, audio pipeline, and a
single diagnostics policy. `ZeroSoundController` is the main-actor use-case and presentation owner.
`ZeroSoundApp` renders discovery, one room surface, its diagnostics inspector, and the compact
menu-bar remote. Views do not own sockets, timers, audio queues, or transitions.

The control protocol uses typed commands and events over one framed TCP session per member. A
separate authenticated UDP plane carries only audio and clock samples, with bounded per-peer sends
that discard stale queued audio instead of accumulating latency. Audio packets carry both source
identity and stream generation, so delayed traffic from a replaced source is rejected. Core room
correctness is tested with an injectable clock, deterministic delivery faults, and real loopback
TCP/UDP integration tests; Bonjour remains passive discovery only.

## Current security boundary

The current prototype is intended for a trusted local office network. Authentication, pairing, and
encrypted audio are required before using ZeroSound on an untrusted LAN; the transport keeps this
as a distinct future authorization boundary rather than mixing it into room state.
