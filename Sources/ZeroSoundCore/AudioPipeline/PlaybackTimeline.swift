import Foundation

/// Maps AVAudioPlayerNode sample time back to the local presentation timeline.
struct PlaybackTimeline: Equatable, Sendable {
  let anchorPresentationNanoseconds: UInt64
  let anchorPlayerSampleTime: Int64

  init(anchorPresentationNanoseconds: UInt64, anchorPlayerSampleTime: Int64 = 0) {
    self.anchorPresentationNanoseconds = anchorPresentationNanoseconds
    self.anchorPlayerSampleTime = anchorPlayerSampleTime
  }

  func phaseErrorNanoseconds(
    renderHostNanoseconds: UInt64,
    playerSampleTime: Int64,
    sampleRate: UInt32,
    outputLatencyNanoseconds: UInt64
  ) -> Int64? {
    guard playerSampleTime >= anchorPlayerSampleTime, sampleRate > 0 else { return nil }
    let actualPresentation = renderHostNanoseconds &+ outputLatencyNanoseconds
    let elapsedPlayerSamples = playerSampleTime - anchorPlayerSampleTime
    let intendedPresentation =
      anchorPresentationNanoseconds
      &+ UInt64(
        (Double(elapsedPlayerSamples) * 1_000_000_000 / Double(sampleRate)).rounded()
      )
    return signedDifference(actualPresentation, intendedPresentation)
  }
}

private func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
  if lhs >= rhs { return Int64(clamping: lhs - rhs) }
  return -Int64(clamping: rhs - lhs)
}
