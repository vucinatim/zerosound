import Foundation

/// A user-facing assessment of the room, ordered by impact.
///
/// Raw transport and playback counters intentionally do not map directly to this value. A healthy
/// real-time system can lose, reorder, and conceal packets without affecting what people hear.
public enum RoomHealthSeverity: Int, Codable, Comparable, Sendable {
  case excellent
  case stabilizing
  case degraded
  case actionRequired

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public var title: String {
    switch self {
    case .excellent: "Excellent"
    case .stabilizing: "Stabilizing"
    case .degraded: "Degraded"
    case .actionRequired: "Action needed"
    }
  }
}

public enum RoomHealthCause: Equatable, Sendable {
  case roomReady
  case playbackStable
  case joining
  case reconnecting
  case preparingAudio
  case measuringSynchronization
  case automaticRecovery
  case restoringTransport
  case transportInterrupted
  case playbackInterrupted
  case actionRequired(String)
}

public struct RoomHealthAssessment: Equatable, Sendable {
  public let severity: RoomHealthSeverity
  public let cause: RoomHealthCause

  public init(severity: RoomHealthSeverity, cause: RoomHealthCause) {
    self.severity = severity
    self.cause = cause
  }

  public var summary: String {
    switch cause {
    case .roomReady: "The room is ready."
    case .playbackStable: "Audio is synchronized and stable."
    case .joining: "This Mac is joining the room."
    case .reconnecting: "ZeroSound is restoring the room connection."
    case .preparingAudio: "The room is preparing the audio stream."
    case .measuringSynchronization: "The speakers are measuring synchronization."
    case .automaticRecovery: "ZeroSound is correcting a temporary playback interruption."
    case .restoringTransport: "ZeroSound is restoring an interrupted room connection."
    case .transportInterrupted: "A room connection is currently unavailable."
    case .playbackInterrupted: "One or more speakers cannot currently maintain playback."
    case .actionRequired(let message): message
    }
  }

  public static let excellent = RoomHealthAssessment(
    severity: .excellent,
    cause: .roomReady
  )
}

/// Pure policy that translates current operational consequences into a user-facing assessment.
/// Packet loss and reordering remain telemetry unless they cause an underrun, failed recovery, or
/// sustained synchronization error.
public struct RoomDiagnosticsPolicy: Sendable {
  /// More than one percent concealed audio in the rolling ten-second window is user-audible
  /// continuity damage, even when the renderer successfully avoids a hard underrun.
  static let degradedConcealedAudioMilliseconds = 100.0

  public init() {}

  public func evaluate(
    snapshot: RoomSnapshot,
    reconnecting: Bool = false,
    transport: TransportDiagnostics = .idle,
    actionRequired: String? = nil
  ) -> RoomHealthAssessment {
    if let actionRequired {
      return RoomHealthAssessment(
        severity: .actionRequired,
        cause: .actionRequired(actionRequired)
      )
    }

    if reconnecting || snapshot.members.contains(where: { $0.connection == .reconnecting }) {
      return RoomHealthAssessment(severity: .stabilizing, cause: .reconnecting)
    }

    if transport.control == .connecting || transport.audio == .registering {
      return RoomHealthAssessment(severity: .stabilizing, cause: .joining)
    }

    if transport.control == .closed || transport.audio == .closed {
      return RoomHealthAssessment(severity: .degraded, cause: .transportInterrupted)
    }

    if transport.control == .degraded || transport.audio == .degraded {
      return RoomHealthAssessment(severity: .stabilizing, cause: .restoringTransport)
    }

    guard snapshot.audioSource.isLive else {
      switch snapshot.audioSource {
      case .assigning, .priming, .stopping:
        return RoomHealthAssessment(severity: .stabilizing, cause: .preparingAudio)
      case .idle, .live:
        return .excellent
      }
    }

    let health = snapshot.members.map(\.playbackHealth)
    if health.contains(where: {
      $0.recentRendererUnderruns > $0.recentResynchronizations + 1
        || $0.recentConcealedAudioMilliseconds >= Self.degradedConcealedAudioMilliseconds
        || abs($0.phaseErrorMilliseconds ?? 0) >= 20
        || ($0.phaseErrorMilliseconds != nil && $0.bufferDepthMilliseconds < 40)
    }) {
      return RoomHealthAssessment(severity: .degraded, cause: .playbackInterrupted)
    }

    if health.contains(where: { $0.phaseErrorMilliseconds == nil }) {
      return RoomHealthAssessment(severity: .stabilizing, cause: .measuringSynchronization)
    }

    if health.contains(where: {
      $0.recentRendererUnderruns > 0
        || $0.recentResynchronizations > 0
        || abs($0.phaseErrorMilliseconds ?? 0) >= 5
        || abs($0.playbackRatePartsPerMillion) > 1_500
    }) {
      return RoomHealthAssessment(severity: .stabilizing, cause: .automaticRecovery)
    }

    return RoomHealthAssessment(severity: .excellent, cause: .playbackStable)
  }
}

/// Prevents the headline status from oscillating when live measurements sit on a boundary.
/// Worsening is immediate; recovery requires consecutive healthy observations. Explicitly idle
/// rooms become healthy immediately because no live playback can still be impaired.
public struct RoomHealthStabilizer: Sendable {
  public private(set) var assessment: RoomHealthAssessment
  private let recoveryObservations: Int
  private var candidate: RoomHealthAssessment?
  private var candidateCount = 0

  public init(
    initial: RoomHealthAssessment = .excellent,
    recoveryObservations: Int = 3
  ) {
    assessment = initial
    self.recoveryObservations = max(1, recoveryObservations)
  }

  public mutating func observe(_ next: RoomHealthAssessment) -> RoomHealthAssessment {
    if next.cause == .roomReady || next.severity >= assessment.severity
      || next.severity != .excellent
    {
      assessment = next
      candidate = nil
      candidateCount = 0
      return assessment
    }

    if candidate == next {
      candidateCount += 1
    } else {
      candidate = next
      candidateCount = 1
    }

    if candidateCount >= recoveryObservations {
      assessment = next
      candidate = nil
      candidateCount = 0
    }
    return assessment
  }

  public mutating func reset(to assessment: RoomHealthAssessment = .excellent) {
    self.assessment = assessment
    candidate = nil
    candidateCount = 0
  }
}
