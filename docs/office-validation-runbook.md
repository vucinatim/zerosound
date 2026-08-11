# ZeroSound v0.8 office validation

Use the same `ZeroSound-0.8.0-macOS-universal.zip` on every Mac. Because this release candidate is
ad-hoc signed, extract it and use **Control-click → Open** on first launch. Keep all Macs on the same
local Wi-Fi and temporarily disable VPNs that intercept local traffic.

For every scenario, open **Room Diagnostics → Copy Diagnostics** on each Mac at the end and save the
reports with the Mac name and scenario. A pass means the room remains usable without restarting or
rejoining; a brief recovery is acceptable only when the scenario deliberately disrupts the network.

## Two-Mac functional pass

1. On Mac A, create **Office Room**. On Mac B, confirm it appears before joining, then join it.
2. Confirm both screens show the same two-member roster within two seconds.
3. Play YouTube on Mac A and choose **Play from this Mac**. Listen for five minutes.
4. Transfer playback to Mac B, then back to Mac A. Confirm there is one bounded interruption, with no
   overlap, click, or lasting offset.
5. Close both main windows. From the menu bar, stop, restart, reopen, and finally leave the room.

Pass criteria: no persistent pop/static, no audible echo or lasting timing shift, no duplicate member,
no capture drops, and no increasing underrun/resynchronization counter during stable playback.

## Five- and eight-Mac room pass

1. Create a fresh room and join the other Macs simultaneously.
2. Confirm every Mac shows the identical roster and source; inspect the room layout in light and dark
   mode at both five and eight members.
3. Start from a non-coordinator Mac and listen from multiple positions in the office for ten minutes.
4. Transfer the source to two other Macs, including one with different hardware when available.
5. While idle, quit the coordinator. Confirm the room remains and converges on one roster without a
   new join flow.
6. Restart audio, then quit the coordinator during live playback. The old timeline must stop cleanly;
   start audio again from a remaining Mac without recreating the room.

Pass criteria: source and coordinator changes converge on every Mac, the old stream never returns,
join readiness remains under two seconds on a healthy LAN, and copied diagnostics agree on room ID,
coordinator term, source, and stream generation.

## Recovery and soak pass

Run an eight-Mac room for at least two hours with normal office Wi-Fi traffic. During the run:

- sleep and wake one non-source Mac, then the source Mac;
- toggle Wi-Fi on one non-source Mac and confirm reconnection within five seconds after the room is
  visible again;
- change an output device and test at least one different supported hardware sample rate;
- deny, grant, and revoke system-audio capture permission on the source;
- enable Reduce Motion, full keyboard access, and VoiceOver for one control pass.

At 15 minutes, one hour, and the end, copy diagnostics from every Mac. Record any audible event with
its approximate time. Fail the run for persistent desynchronization, repeated automatic resyncs on a
stable network, unbounded counter growth, a lost/duplicated member, a crash, or a room that requires
manual recreation after coordinator departure.

## Result record

| Scenario | Macs/hardware | Duration | Result | Diagnostic reports / notes |
| --- | --- | ---: | --- | --- |
| Two-Mac functional | | | Pending | |
| Five-Mac room | | | Pending | |
| Eight-Mac room | | | Pending | |
| Coordinator departure | | | Pending | |
| Recovery and soak | | | Pending | |
| Accessibility and appearance | | | Pending | |
