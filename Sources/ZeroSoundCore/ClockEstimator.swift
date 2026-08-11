import Foundation

/// One NTP-style exchange expressed on both machines' monotonic timelines.
/// Midpoints remove time spent processing the ping on the coordinator.
public struct ClockSample: Equatable, Sendable {
  public let roundTripNanoseconds: UInt64
  public let coordinatorOffsetNanoseconds: Int64
  public let clientMidpointNanoseconds: UInt64
  public let coordinatorMidpointNanoseconds: UInt64

  public init(
    clientSend: UInt64,
    coordinatorReceive: UInt64,
    coordinatorSend: UInt64,
    clientReceive: UInt64
  ) {
    let clientElapsed = clientReceive &- clientSend
    let coordinatorElapsed = coordinatorSend &- coordinatorReceive
    roundTripNanoseconds =
      clientElapsed >= coordinatorElapsed ? clientElapsed - coordinatorElapsed : 0

    clientMidpointNanoseconds = clientSend &+ clientElapsed / 2
    coordinatorMidpointNanoseconds = coordinatorReceive &+ coordinatorElapsed / 2
    coordinatorOffsetNanoseconds = signedDifference(
      coordinatorMidpointNanoseconds,
      clientMidpointNanoseconds
    )
  }
}

/// A continuous affine mapping between one Mac's monotonic clock and room time.
///
/// The network samples contain both clock skew and one-way Wi-Fi jitter. The estimator uses a
/// low-latency sample set for an affine fit, then slews phase corrections into the active mapping.
/// Consequently a newly selected network sample can never jump the playback timeline.
public struct ClockEstimator: Sendable {
  private static let minimumLockSamples = 4
  private static let lowLatencySlackNanoseconds: UInt64 = 2_000_000
  private static let minimumRateFitSpanNanoseconds: UInt64 = 8_000_000_000
  private static let maximumRateError = 250.0 / 1_000_000
  private static let rateSmoothingFactor = 0.08
  private static let phaseSmoothingFactor = 0.2
  private static let maximumPhaseSlewPerSampleNanoseconds = 250_000.0

  private let capacity: Int
  private var samples: [ClockSample] = []
  private var referenceLocalNanoseconds: UInt64?
  private var referenceCoordinatorNanoseconds = 0.0

  public private(set) var clockRate = 1.0

  public init(capacity: Int = 120) {
    self.capacity = max(Self.minimumLockSamples, capacity)
  }

  public var sampleCount: Int { samples.count }
  public var isLocked: Bool { referenceLocalNanoseconds != nil }

  /// Coordinator minus local time at the model's current reference point.
  public var coordinatorOffsetNanoseconds: Int64? {
    guard let referenceLocalNanoseconds else { return nil }
    return Int64(
      clamping: Int64(referenceCoordinatorNanoseconds.rounded())
        - Int64(clamping: referenceLocalNanoseconds)
    )
  }

  public var bestRoundTripNanoseconds: UInt64? {
    samples.map(\.roundTripNanoseconds).min()
  }

  public var clockRatePartsPerMillion: Double {
    (clockRate - 1) * 1_000_000
  }

  public mutating func add(_ sample: ClockSample) {
    samples.append(sample)
    if samples.count > capacity {
      samples.removeFirst(samples.count - capacity)
    }

    guard samples.count >= Self.minimumLockSamples else { return }
    if referenceLocalNanoseconds == nil {
      bootstrapFromBestSample()
    } else {
      updateModel(referenceLocal: sample.clientMidpointNanoseconds)
    }
  }

  public func localTime(forCoordinatorTime coordinatorTime: UInt64) -> UInt64? {
    guard let referenceLocalNanoseconds else { return nil }
    let coordinatorDelta = Double(coordinatorTime) - referenceCoordinatorNanoseconds
    return clampedUInt64(Double(referenceLocalNanoseconds) + coordinatorDelta / clockRate)
  }

  public func coordinatorTime(forLocalTime localTime: UInt64) -> UInt64? {
    guard let referenceLocalNanoseconds else { return nil }
    let localDelta = signedDoubleDifference(localTime, referenceLocalNanoseconds)
    return clampedUInt64(referenceCoordinatorNanoseconds + localDelta * clockRate)
  }

  private mutating func bootstrapFromBestSample() {
    guard let best = samples.min(by: { $0.roundTripNanoseconds < $1.roundTripNanoseconds }) else {
      return
    }
    referenceLocalNanoseconds = best.clientMidpointNanoseconds
    referenceCoordinatorNanoseconds = Double(best.coordinatorMidpointNanoseconds)
    clockRate = 1
  }

  private mutating func updateModel(referenceLocal: UInt64) {
    guard
      let currentReferenceLocal = referenceLocalNanoseconds,
      let minimumRoundTrip = bestRoundTripNanoseconds
    else { return }

    let latencyLimit = minimumRoundTrip &+ Self.lowLatencySlackNanoseconds
    let candidates = samples.filter { $0.roundTripNanoseconds <= latencyLimit }
    guard !candidates.isEmpty else { return }

    let fittedRate = fittedClockRate(from: candidates) ?? clockRate
    let boundedRate = min(
      1 + Self.maximumRateError,
      max(1 - Self.maximumRateError, fittedRate)
    )
    let updatedRate =
      clockRate + (boundedRate - clockRate) * Self.rateSmoothingFactor

    let coordinatorAtReference = candidates.map { candidate in
      Double(candidate.coordinatorMidpointNanoseconds)
        + signedDoubleDifference(referenceLocal, candidate.clientMidpointNanoseconds)
        * updatedRate
    }.median

    let predictedCoordinator =
      referenceCoordinatorNanoseconds
      + signedDoubleDifference(referenceLocal, currentReferenceLocal) * clockRate
    let phaseError = coordinatorAtReference - predictedCoordinator
    let requestedCorrection = phaseError * Self.phaseSmoothingFactor
    let phaseCorrection = min(
      Self.maximumPhaseSlewPerSampleNanoseconds,
      max(-Self.maximumPhaseSlewPerSampleNanoseconds, requestedCorrection)
    )

    referenceLocalNanoseconds = referenceLocal
    referenceCoordinatorNanoseconds = predictedCoordinator + phaseCorrection
    clockRate = updatedRate
  }

  private func fittedClockRate(from candidates: [ClockSample]) -> Double? {
    guard
      let first = candidates.first,
      let last = candidates.last,
      last.clientMidpointNanoseconds >= first.clientMidpointNanoseconds,
      last.clientMidpointNanoseconds - first.clientMidpointNanoseconds
        >= Self.minimumRateFitSpanNanoseconds
    else { return nil }

    let localOrigin = first.clientMidpointNanoseconds
    let coordinatorOrigin = first.coordinatorMidpointNanoseconds
    var totalWeight = 0.0
    var weightedLocal = 0.0
    var weightedCoordinator = 0.0
    var observations: [(local: Double, coordinator: Double, weight: Double)] = []
    observations.reserveCapacity(candidates.count)

    let minimumRoundTrip = Double(bestRoundTripNanoseconds ?? 0)
    for candidate in candidates {
      let local = signedDoubleDifference(candidate.clientMidpointNanoseconds, localOrigin)
      let coordinator = signedDoubleDifference(
        candidate.coordinatorMidpointNanoseconds,
        coordinatorOrigin
      )
      let excessLatency = max(0, Double(candidate.roundTripNanoseconds) - minimumRoundTrip)
      let normalizedLatency = excessLatency / 1_000_000
      let weight = 1 / (1 + normalizedLatency * normalizedLatency)
      observations.append((local, coordinator, weight))
      totalWeight += weight
      weightedLocal += local * weight
      weightedCoordinator += coordinator * weight
    }
    guard totalWeight > 0 else { return nil }

    let meanLocal = weightedLocal / totalWeight
    let meanCoordinator = weightedCoordinator / totalWeight
    var covariance = 0.0
    var variance = 0.0
    for observation in observations {
      let localDelta = observation.local - meanLocal
      covariance += observation.weight * localDelta * (observation.coordinator - meanCoordinator)
      variance += observation.weight * localDelta * localDelta
    }
    guard variance > 0 else { return nil }
    return covariance / variance
  }
}

private func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
  if lhs >= rhs {
    return Int64(clamping: lhs - rhs)
  }
  return -Int64(clamping: rhs - lhs)
}

private func signedDoubleDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
  if lhs >= rhs { return Double(lhs - rhs) }
  return -Double(rhs - lhs)
}

private func clampedUInt64(_ value: Double) -> UInt64 {
  guard value.isFinite, value > 0 else { return 0 }
  return UInt64(min(Double(UInt64.max), value).rounded())
}

extension Array where Element == Double {
  fileprivate var median: Double {
    let ordered = sorted()
    let middle = ordered.count / 2
    if ordered.count.isMultiple(of: 2) {
      return (ordered[middle - 1] + ordered[middle]) / 2
    }
    return ordered[middle]
  }
}
