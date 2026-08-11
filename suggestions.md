# Architecture follow-ups

The approved product and architecture rewrite is specified in
[`docs/v0.8-room-rewrite-plan.md`](docs/v0.8-room-rewrite-plan.md).

The room domain, typed protocol, coordinator recovery, transferable audio path, diagnostics policy,
Core Audio pipeline, and release tooling now have clean ownership boundaries. These are intentionally
deferred product-level investments rather than shortcuts inside the v0.8 architecture.

1. Run multi-hour, eight-Mac room soak tests to tune the jitter deadline, recovery lead, clock-discipline fit window, and phase-controller limits across mixed hardware and congested office Wi-Fi. The app now exports live phase error, clock skew, rolling loss, and phase-resynchronization counts needed to make this empirical rather than subjective.
2. Add authenticated pairing and encrypted audio before using ZeroSound on an untrusted or shared LAN.
3. Consider forward-error correction or Opus only if soak-test packet-loss measurements show that crossfade concealment is insufficient.
4. Measure browser video lip-sync before deciding whether a virtual AudioDriverKit output device is justified.
5. Install a Developer ID Application certificate and notary credentials. The release script already enables the hardened runtime, signs the universal binary, submits it, and staples the result when those credentials are available.
