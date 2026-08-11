import Foundation

/// Defines one unambiguous relationship between content time, the player timeline, and the
/// hardware render clock. The first content frame is always player sample zero; the player itself
/// starts early enough for that frame to reach the speakers at its room presentation time.
struct PlaybackStartPlan: Equatable, Sendable {
  let presentationNanoseconds: UInt64
  let renderStartNanoseconds: UInt64
  let playerSampleOrigin: Int64
}

struct PlaybackStartPlanner: Sendable {
  private let minimumSchedulingLeadNanoseconds: UInt64

  init(minimumSchedulingLeadNanoseconds: UInt64 = 5_000_000) {
    self.minimumSchedulingLeadNanoseconds = minimumSchedulingLeadNanoseconds
  }

  func plan(
    presentationNanoseconds: UInt64,
    outputLatencyNanoseconds: UInt64,
    nowNanoseconds: UInt64
  ) -> PlaybackStartPlan? {
    guard presentationNanoseconds >= outputLatencyNanoseconds else { return nil }
    let renderStart = presentationNanoseconds - outputLatencyNanoseconds
    guard renderStart >= nowNanoseconds &+ minimumSchedulingLeadNanoseconds else { return nil }
    return PlaybackStartPlan(
      presentationNanoseconds: presentationNanoseconds,
      renderStartNanoseconds: renderStart,
      playerSampleOrigin: 0
    )
  }
}
