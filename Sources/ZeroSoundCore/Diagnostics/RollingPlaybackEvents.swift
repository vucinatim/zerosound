import Foundation

struct PlaybackEventCounters: Equatable, Sendable {
  var missingPackets: UInt64 = 0
  var concealedFrames: UInt64 = 0
  var latePackets: UInt64 = 0
  var reorderedPackets: UInt64 = 0
  var rendererUnderruns: UInt64 = 0
  var resynchronizations: UInt64 = 0
}

struct RollingPlaybackEvents: Equatable, Sendable {
  private struct Event: Equatable, Sendable {
    let timestampNanoseconds: UInt64
    let counters: PlaybackEventCounters
  }

  private let windowNanoseconds: UInt64
  private var previous = PlaybackEventCounters()
  private var events: [Event] = []

  init(windowNanoseconds: UInt64 = 10_000_000_000) {
    self.windowNanoseconds = max(1, windowNanoseconds)
  }

  mutating func observe(
    _ cumulative: PlaybackEventCounters,
    at timestampNanoseconds: UInt64
  ) -> PlaybackEventCounters {
    let delta = PlaybackEventCounters(
      missingPackets: increment(from: previous.missingPackets, to: cumulative.missingPackets),
      concealedFrames: increment(from: previous.concealedFrames, to: cumulative.concealedFrames),
      latePackets: increment(from: previous.latePackets, to: cumulative.latePackets),
      reorderedPackets: increment(
        from: previous.reorderedPackets,
        to: cumulative.reorderedPackets
      ),
      rendererUnderruns: increment(
        from: previous.rendererUnderruns,
        to: cumulative.rendererUnderruns
      ),
      resynchronizations: increment(
        from: previous.resynchronizations,
        to: cumulative.resynchronizations
      )
    )
    previous = cumulative
    if delta != PlaybackEventCounters() {
      events.append(Event(timestampNanoseconds: timestampNanoseconds, counters: delta))
    }

    let cutoff =
      timestampNanoseconds > windowNanoseconds
      ? timestampNanoseconds - windowNanoseconds : 0
    events.removeAll { $0.timestampNanoseconds < cutoff }
    return events.reduce(into: PlaybackEventCounters()) { total, event in
      total.missingPackets &+= event.counters.missingPackets
      total.concealedFrames &+= event.counters.concealedFrames
      total.latePackets &+= event.counters.latePackets
      total.reorderedPackets &+= event.counters.reorderedPackets
      total.rendererUnderruns &+= event.counters.rendererUnderruns
      total.resynchronizations &+= event.counters.resynchronizations
    }
  }

  mutating func reset() {
    previous = PlaybackEventCounters()
    events.removeAll(keepingCapacity: true)
  }
}

private func increment(from previous: UInt64, to current: UInt64) -> UInt64 {
  current >= previous ? current - previous : current
}
