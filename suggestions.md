# Architecture follow-ups

The approved product and architecture rewrite is specified in
[`docs/v0.8-room-rewrite-plan.md`](docs/v0.8-room-rewrite-plan.md).

The v0.11 reliability architecture is specified in
[`docs/v0.11-reliable-transport-and-sync-plan.md`](docs/v0.11-reliable-transport-and-sync-plan.md).
Its implementation now replaces shared UDP control/audio transport with framed TCP control plus
dedicated UDP audio and continuously reconciles playback against the current room clock. The
remaining release gate is measured two/five/eight-Mac office validation and update testing, not more
transport architecture.

The consequence-based diagnostics architecture is specified in
[`docs/v0.12-diagnostics-system.md`](docs/v0.12-diagnostics-system.md). Raw telemetry, derived room
health, presentation hysteresis, and stream metric lifecycles now have separate responsibilities.

The room domain, typed protocol, coordinator recovery, transferable audio path, diagnostics policy,
Core Audio pipeline, and release tooling now have clean ownership boundaries. These are intentionally
deferred product-level investments rather than shortcuts inside the v0.8 architecture.

1. Run multi-hour, eight-Mac room soak tests to tune the jitter deadline, recovery lead, clock-discipline fit window, and phase-controller limits across mixed hardware and congested office Wi-Fi. The app now exports live phase error, clock skew, rolling loss, and phase-resynchronization counts needed to make this empirical rather than subjective.
2. Add authenticated pairing and encrypted audio before using ZeroSound on an untrusted or shared LAN.
3. Consider forward-error correction or Opus only if soak-test packet-loss measurements show that crossfade concealment is insufficient.
4. Measure browser video lip-sync before deciding whether a virtual AudioDriverKit output device is justified.
5. Install a Developer ID Application certificate and notary credentials. The release script already enables the hardened runtime, signs the universal binary, submits it, and staples the result when those credentials are available.
6. Add a repeatable audio-device integration harness that records AVAudioPlayerNode host time, player sample time, and physical loopback timing across output-device and sample-rate changes. Pure timeline tests protect the scheduling contract, while this harness would catch OS- or hardware-specific Core Audio behavior before release.
7. Tune the 100 ms per ten-second audible-concealment health budget with office listening tests. The
   metric is now expressed as damaged audio duration rather than packet count, so future packet-size
   or codec changes will not silently change the meaning of room health.
8. Validate the 64-datagram local send window under eight simultaneous receivers during the office
   soak test. It isolates backpressure per receiver and caps retained audio near 64 KB per Mac; the
   existing pre-send-drop counter will show whether that bound is ever reached in practice.
