import Foundation

enum PlaybackPhaseDecision: Equatable, Sendable {
  case adjustRate(Double)
  case reanchor
}

/// Keeps the hardware playhead locked to the room timeline.
///
/// Positive phase error means the speaker is late, so playback is accelerated. The controller
/// deliberately uses a slow proportional correction: small errors disappear without pitch or
/// tempo artifacts, while a sustained discontinuity asks the renderer for a clean re-anchor.
struct PlaybackPhaseController: Sendable {
  private let correctionHorizonSeconds: Double
  private let maximumRateCorrection: Double
  private let phaseFilterFactor: Double
  private let rateFilterFactor: Double
  private let deadbandNanoseconds: Double
  private let reanchorThresholdNanoseconds: Double
  private let reanchorPersistenceNanoseconds: UInt64

  private var excessiveErrorStartedNanoseconds: UInt64?
  private var didRequestReanchor = false

  private(set) var filteredPhaseErrorNanoseconds: Double?
  private(set) var playbackRate = 1.0

  init(
    correctionHorizonSeconds: Double = 8,
    maximumRateCorrectionPartsPerMillion: Double = 2_500,
    phaseFilterFactor: Double = 0.18,
    rateFilterFactor: Double = 0.15,
    deadbandMilliseconds: Double = 0.35,
    reanchorThresholdMilliseconds: Double = 45,
    reanchorPersistenceNanoseconds: UInt64 = 1_500_000_000
  ) {
    self.correctionHorizonSeconds = max(1, correctionHorizonSeconds)
    maximumRateCorrection = max(0, maximumRateCorrectionPartsPerMillion) / 1_000_000
    self.phaseFilterFactor = min(1, max(0.01, phaseFilterFactor))
    self.rateFilterFactor = min(1, max(0.01, rateFilterFactor))
    deadbandNanoseconds = max(0, deadbandMilliseconds) * 1_000_000
    reanchorThresholdNanoseconds = max(1, reanchorThresholdMilliseconds) * 1_000_000
    self.reanchorPersistenceNanoseconds = reanchorPersistenceNanoseconds
  }

  var phaseErrorMilliseconds: Double? {
    filteredPhaseErrorNanoseconds.map { $0 / 1_000_000 }
  }

  mutating func observe(
    phaseErrorNanoseconds: Int64,
    at observationNanoseconds: UInt64
  ) -> PlaybackPhaseDecision {
    let rawError = Double(phaseErrorNanoseconds)
    if let filteredPhaseErrorNanoseconds {
      self.filteredPhaseErrorNanoseconds =
        filteredPhaseErrorNanoseconds
        + (rawError - filteredPhaseErrorNanoseconds) * phaseFilterFactor
    } else {
      filteredPhaseErrorNanoseconds = rawError
    }

    guard let filteredError = filteredPhaseErrorNanoseconds else {
      return .adjustRate(playbackRate)
    }

    if abs(filteredError) >= reanchorThresholdNanoseconds {
      if excessiveErrorStartedNanoseconds == nil {
        excessiveErrorStartedNanoseconds = observationNanoseconds
      } else if !didRequestReanchor,
        observationNanoseconds >= excessiveErrorStartedNanoseconds!
          &+ reanchorPersistenceNanoseconds
      {
        didRequestReanchor = true
        return .reanchor
      }
    } else {
      excessiveErrorStartedNanoseconds = nil
    }

    let actionableError = abs(filteredError) >= deadbandNanoseconds ? filteredError : 0
    let requestedCorrection =
      actionableError / 1_000_000_000 / correctionHorizonSeconds
    let boundedCorrection = min(
      maximumRateCorrection,
      max(-maximumRateCorrection, requestedCorrection)
    )
    let targetRate = 1 + boundedCorrection
    playbackRate += (targetRate - playbackRate) * rateFilterFactor
    return .adjustRate(playbackRate)
  }

  mutating func reset() {
    excessiveErrorStartedNanoseconds = nil
    didRequestReanchor = false
    filteredPhaseErrorNanoseconds = nil
    playbackRate = 1
  }
}
