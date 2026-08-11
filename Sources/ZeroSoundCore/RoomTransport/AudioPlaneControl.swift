import Foundation

enum AudioPlaneControl: Codable, Equatable, Sendable {
  case register(
    roomID: RoomID,
    memberID: MemberID,
    coordinatorTerm: UInt64,
    token: UUID
  )
  case clockPing(sequence: UInt64, clientSendNanoseconds: UInt64)
  case clockPong(
    sequence: UInt64,
    clientSendNanoseconds: UInt64,
    coordinatorReceiveNanoseconds: UInt64,
    coordinatorSendNanoseconds: UInt64
  )
}

enum AudioPlaneControlCodec {
  private static let magic = Data([0x5A, 0x53, 0x54, 0x31])  // ZST1
  private static let maximumPayloadBytes = 2_048

  static func encode(_ message: AudioPlaneControl) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(message)
    guard payload.count <= maximumPayloadBytes else {
      throw ControlFrameError.frameTooLarge(payload.count)
    }
    return magic + payload
  }

  static func decode(_ data: Data) throws -> AudioPlaneControl? {
    guard data.count >= magic.count, data.prefix(magic.count) == magic else { return nil }
    let payload = data.dropFirst(magic.count)
    guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
      throw ControlFrameError.frameTooLarge(payload.count)
    }
    return try JSONDecoder().decode(AudioPlaneControl.self, from: payload)
  }
}
