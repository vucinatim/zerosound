import Foundation

/// Continuously maps rendered content samples to coordinator room time.
///
/// Packet presentation timestamps remain authoritative after startup. Observations gently update the
/// stream phase and learn source-clock rate, while the renderer separately converts room time through
/// its latest `RoomClockMapping` snapshot.
struct StreamTimeline: Sendable {
  private static let observationCapacity = 128
  private static let rateSmoothingFactor = 0.1
  private static let phaseSmoothingFactor = 0.1
  private static let maximumSourceRateError = 500.0 / 1_000_000
  private static let maximumPhaseSlewPerObservationNanoseconds = 100_000.0

  let sampleRate: UInt32
  private let originPlayerSampleTime: Int64
  private(set) var referencePlayerSampleTime: Int64
  private(set) var referenceRoomNanoseconds: Double
  private(set) var roomNanosecondsPerSample: Double
  private var observations: [StreamTimingObservation]

  init(
    anchorRoomPresentationNanoseconds: UInt64,
    anchorPlayerSampleTime: Int64,
    sampleRate: UInt32
  ) {
    self.sampleRate = sampleRate
    originPlayerSampleTime = anchorPlayerSampleTime
    referencePlayerSampleTime = anchorPlayerSampleTime
    referenceRoomNanoseconds = Double(anchorRoomPresentationNanoseconds)
    roomNanosecondsPerSample = 1_000_000_000 / Double(max(1, sampleRate))
    observations = [
      StreamTimingObservation(
        playerSampleTime: anchorPlayerSampleTime,
        roomPresentationNanoseconds: anchorRoomPresentationNanoseconds
      )
    ]
  }

  mutating func observe(
    roomPresentationNanoseconds: UInt64,
    atPlayerSampleTime playerSampleTime: Int64
  ) {
    guard sampleRate > 0, playerSampleTime >= referencePlayerSampleTime else { return }
    if observations.last?.playerSampleTime == playerSampleTime { return }

    observations.append(
      StreamTimingObservation(
        playerSampleTime: playerSampleTime,
        roomPresentationNanoseconds: roomPresentationNanoseconds
      ))
    if observations.count > Self.observationCapacity {
      observations.removeFirst(observations.count - Self.observationCapacity)
    }

    let predictedRoom = roomTimeDouble(forPlayerSampleTime: playerSampleTime)
    updateRateIfPossible()
    let phaseError = Double(roomPresentationNanoseconds) - predictedRoom
    let requestedCorrection = phaseError * Self.phaseSmoothingFactor
    let phaseCorrection = min(
      Self.maximumPhaseSlewPerObservationNanoseconds,
      max(-Self.maximumPhaseSlewPerObservationNanoseconds, requestedCorrection)
    )
    referencePlayerSampleTime = playerSampleTime
    referenceRoomNanoseconds = predictedRoom + phaseCorrection
  }

  func roomTime(forPlayerSampleTime playerSampleTime: Int64) -> UInt64? {
    guard sampleRate > 0, playerSampleTime >= originPlayerSampleTime else { return nil }
    let value = roomTimeDouble(forPlayerSampleTime: playerSampleTime)
    guard value.isFinite, value >= 0, value <= Double(UInt64.max) else { return nil }
    return UInt64(value.rounded())
  }

  func phaseErrorNanoseconds(
    renderHostNanoseconds: UInt64,
    playerSampleTime: Int64,
    outputLatencyNanoseconds: UInt64,
    roomClockMapping: RoomClockMapping
  ) -> Int64? {
    let actualPresentation = renderHostNanoseconds &+ outputLatencyNanoseconds
    guard
      let intendedRoomPresentation = roomTime(forPlayerSampleTime: playerSampleTime),
      let intendedLocalPresentation = roomClockMapping.localTime(
        forRoomTime: intendedRoomPresentation)
    else { return nil }
    return signedTimelineDifference(actualPresentation, intendedLocalPresentation)
  }

  private func roomTimeDouble(forPlayerSampleTime playerSampleTime: Int64) -> Double {
    referenceRoomNanoseconds
      + Double(playerSampleTime - referencePlayerSampleTime) * roomNanosecondsPerSample
  }

  private mutating func updateRateIfPossible() {
    guard
      let first = observations.first,
      let last = observations.last,
      last.playerSampleTime > first.playerSampleTime,
      last.playerSampleTime - first.playerSampleTime >= Int64(sampleRate) * 2
    else { return }

    let playerSpan = Double(last.playerSampleTime - first.playerSampleTime)
    let roomSpan = timelineDoubleDifference(
      last.roomPresentationNanoseconds,
      first.roomPresentationNanoseconds
    )
    let observedRate = roomSpan / playerSpan
    let nominalRate = 1_000_000_000 / Double(sampleRate)
    let minimumRate = nominalRate * (1 - Self.maximumSourceRateError)
    let maximumRate = nominalRate * (1 + Self.maximumSourceRateError)
    let boundedRate = min(maximumRate, max(minimumRate, observedRate))
    roomNanosecondsPerSample +=
      (boundedRate - roomNanosecondsPerSample) * Self.rateSmoothingFactor
  }
}

private struct StreamTimingObservation: Sendable {
  let playerSampleTime: Int64
  let roomPresentationNanoseconds: UInt64
}

private func signedTimelineDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
  lhs >= rhs ? Int64(clamping: lhs - rhs) : -Int64(clamping: rhs - lhs)
}

private func timelineDoubleDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
  lhs >= rhs ? Double(lhs - rhs) : -Double(rhs - lhs)
}
