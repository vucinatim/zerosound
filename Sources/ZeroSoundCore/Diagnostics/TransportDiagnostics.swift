import Foundation

public enum TransportLinkState: String, Codable, Equatable, Sendable {
  case inactive
  case connecting
  case registering
  case ready
  case local
  case degraded
  case closed
}

public struct TransportDiagnostics: Codable, Equatable, Sendable {
  public let control: TransportLinkState
  public let audio: TransportLinkState
  public let joinStage: String
  public let audioDatagramsDroppedBeforeSend: UInt64

  public init(
    control: TransportLinkState = .inactive,
    audio: TransportLinkState = .inactive,
    joinStage: String = "Idle",
    audioDatagramsDroppedBeforeSend: UInt64 = 0
  ) {
    self.control = control
    self.audio = audio
    self.joinStage = joinStage
    self.audioDatagramsDroppedBeforeSend = audioDatagramsDroppedBeforeSend
  }

  public func withAudioDatagramsDroppedBeforeSend(_ count: UInt64) -> Self {
    Self(
      control: control,
      audio: audio,
      joinStage: joinStage,
      audioDatagramsDroppedBeforeSend: count
    )
  }

  public static let idle = TransportDiagnostics()
  public static let localCoordinator = TransportDiagnostics(
    control: .local,
    audio: .local,
    joinStage: "Hosting"
  )

  private enum CodingKeys: String, CodingKey {
    case control
    case audio
    case joinStage
    case audioDatagramsDroppedBeforeSend
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    control = try values.decode(TransportLinkState.self, forKey: .control)
    audio = try values.decode(TransportLinkState.self, forKey: .audio)
    joinStage = try values.decode(String.self, forKey: .joinStage)
    audioDatagramsDroppedBeforeSend =
      try values.decodeIfPresent(UInt64.self, forKey: .audioDatagramsDroppedBeforeSend) ?? 0
  }
}
