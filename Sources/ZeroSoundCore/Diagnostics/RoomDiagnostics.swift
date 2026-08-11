import Foundation

public enum RoomHealthSeverity: Int, Codable, Comparable, Sendable {
  case excellent
  case good
  case recovering
  case needsAttention

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public var title: String {
    switch self {
    case .excellent: "Excellent"
    case .good: "Good"
    case .recovering: "Recovering"
    case .needsAttention: "Needs attention"
    }
  }
}

public struct RoomDiagnosticsPolicy: Sendable {
  public init() {}

  public func evaluate(snapshot: RoomSnapshot, reconnecting: Bool = false) -> RoomHealthSeverity {
    if reconnecting || snapshot.members.contains(where: { $0.connection == .reconnecting }) {
      return .recovering
    }
    let health = snapshot.members.map(\.playbackHealth)
    if health.contains(where: {
      $0.recentRendererUnderruns > $0.recentResynchronizations + 1
        || $0.recentMissingPackets >= 12
        || abs($0.phaseErrorMilliseconds ?? 0) >= 20
        || ($0.phaseErrorMilliseconds != nil && $0.bufferDepthMilliseconds < 40
          && snapshot.audioSource.isLive)
    }) {
      return .needsAttention
    }
    if snapshot.audioSource.isLive
      && health.contains(where: { $0.phaseErrorMilliseconds == nil })
    {
      return .recovering
    }
    if health.contains(where: {
      $0.recentRendererUnderruns > 0 || $0.recentMissingPackets > 2
        || abs($0.phaseErrorMilliseconds ?? 0) >= 5
        || abs($0.playbackRatePartsPerMillion) > 750
    }) {
      return .recovering
    }
    if health.contains(where: {
      $0.recentMissingPackets > 0 || $0.recentReorderedPackets > 0
        || abs($0.phaseErrorMilliseconds ?? 0) >= 2
        || ($0.bufferDepthMilliseconds > 0 && $0.bufferDepthMilliseconds < 100)
    }) {
      return .good
    }
    return .excellent
  }
}
