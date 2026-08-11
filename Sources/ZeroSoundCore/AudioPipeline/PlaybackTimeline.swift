import Foundation

/// Maps AVAudioPlayerNode sample time back to the local presentation timeline.
struct PlaybackTimeline: Equatable, Sendable {
  let anchorPresentationNanoseconds: UInt64

  func phaseErrorNanoseconds(
    renderHostNanoseconds: UInt64,
    playerSampleTime: Int64,
    sampleRate: UInt32,
    outputLatencyNanoseconds: UInt64
  ) -> Int64? {
    guard playerSampleTime >= 0, sampleRate > 0 else { return nil }
    let actualPresentation = renderHostNanoseconds &+ outputLatencyNanoseconds
    let intendedPresentation =
      anchorPresentationNanoseconds
      &+ UInt64(
        (Double(playerSampleTime) * 1_000_000_000 / Double(sampleRate)).rounded()
      )
    return signedDifference(actualPresentation, intendedPresentation)
  }
}

private func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
  if lhs >= rhs { return Int64(clamping: lhs - rhs) }
  return -Int64(clamping: rhs - lhs)
}
