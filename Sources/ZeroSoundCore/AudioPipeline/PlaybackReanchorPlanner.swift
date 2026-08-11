import Foundation

/// Selects an already-buffered batch that is far enough in the future to schedule absolutely.
struct PlaybackReanchorPlanner: Equatable, Sendable {
  let minimumLeadNanoseconds: UInt64

  init(minimumLeadNanoseconds: UInt64 = 120_000_000) {
    self.minimumLeadNanoseconds = minimumLeadNanoseconds
  }

  func anchorIndex(
    in presentationNanoseconds: [UInt64],
    nowNanoseconds: UInt64
  ) -> Int? {
    let earliestPresentation = nowNanoseconds &+ minimumLeadNanoseconds
    return presentationNanoseconds.firstIndex { $0 >= earliestPresentation }
  }
}
