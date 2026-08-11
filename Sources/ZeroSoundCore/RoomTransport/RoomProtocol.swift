import Foundation

public enum ZeroSoundProtocol {
  public static let controlVersion: UInt16 = 9
  public static let audioVersion: UInt8 = 2
  public static let appVersion = "0.10.1"
  public static let serviceType = "_zerosound-room._udp"
}

public struct ProtocolHeader: Codable, Equatable, Sendable {
  public let controlVersion: UInt16
  public let audioVersion: UInt8
  public let appVersion: String
  public let roomID: RoomID
  public let senderID: MemberID
  public let coordinatorTerm: UInt64

  public init(
    roomID: RoomID,
    senderID: MemberID,
    coordinatorTerm: UInt64,
    controlVersion: UInt16 = ZeroSoundProtocol.controlVersion,
    audioVersion: UInt8 = ZeroSoundProtocol.audioVersion,
    appVersion: String = ZeroSoundProtocol.appVersion
  ) {
    self.controlVersion = controlVersion
    self.audioVersion = audioVersion
    self.appVersion = appVersion
    self.roomID = roomID
    self.senderID = senderID
    self.coordinatorTerm = coordinatorTerm
  }

  public var isCompatible: Bool {
    controlVersion == ZeroSoundProtocol.controlVersion
      && audioVersion == ZeroSoundProtocol.audioVersion
  }
}

public enum ControlPayload: Codable, Equatable, Sendable {
  case command(RoomCommand)
  case event(RoomEvent)
  case clockPing(sequence: UInt64, clientSendNanoseconds: UInt64)
  case clockPong(
    sequence: UInt64,
    clientSendNanoseconds: UInt64,
    coordinatorReceiveNanoseconds: UInt64,
    coordinatorSendNanoseconds: UInt64
  )
}

public struct ControlMessage: Codable, Equatable, Sendable {
  public let header: ProtocolHeader
  public let payload: ControlPayload

  public init(header: ProtocolHeader, payload: ControlPayload) {
    self.header = header
    self.payload = payload
  }
}

enum ControlCodec {
  static func encode(_ message: ControlMessage) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(message)
  }

  static func decode(_ data: Data) throws -> ControlMessage {
    try JSONDecoder().decode(ControlMessage.self, from: data)
  }
}
