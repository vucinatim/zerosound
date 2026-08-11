import Foundation

public struct RoomID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public var description: String { rawValue.uuidString }
}

public struct MemberID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public var description: String { rawValue.uuidString }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.uuidString < rhs.rawValue.uuidString
  }
}

public enum MemberConnectionState: String, Codable, Hashable, Sendable {
  case synchronizing
  case ready
  case reconnecting
}

public struct RoomMember: Identifiable, Codable, Hashable, Sendable {
  public let id: MemberID
  public var name: String
  public var appVersion: String
  public var connection: MemberConnectionState
  public var roundTripNanoseconds: UInt64?
  public var worstRoundTripNanoseconds: UInt64?
  public var playbackHealth: PlaybackHealth
  public var audioLevel: Float

  public init(
    id: MemberID,
    name: String,
    appVersion: String = ZeroSoundProtocol.appVersion,
    connection: MemberConnectionState = .synchronizing,
    roundTripNanoseconds: UInt64? = nil,
    worstRoundTripNanoseconds: UInt64? = nil,
    playbackHealth: PlaybackHealth = PlaybackHealth(),
    audioLevel: Float = 0
  ) {
    self.id = id
    self.name = Self.clean(name)
    self.appVersion = appVersion
    self.connection = connection
    self.roundTripNanoseconds = roundTripNanoseconds
    self.worstRoundTripNanoseconds = worstRoundTripNanoseconds
    self.playbackHealth = playbackHealth
    self.audioLevel = min(1, max(0, audioLevel))
  }

  private static func clean(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(64))
  }
}

public enum AudioSourceState: Codable, Hashable, Sendable {
  case idle
  case assigning(MemberID)
  case priming(MemberID)
  case live(MemberID)
  case stopping(MemberID)

  public var memberID: MemberID? {
    switch self {
    case .idle: nil
    case .assigning(let id), .priming(let id), .live(let id), .stopping(let id): id
    }
  }

  public var isLive: Bool {
    if case .live = self { true } else { false }
  }
}

public struct RoomSnapshot: Codable, Hashable, Sendable {
  public let id: RoomID
  public var name: String
  public var coordinatorID: MemberID
  public var coordinatorTerm: UInt64
  public var revision: UInt64
  public var streamGeneration: UInt64
  public var audioSource: AudioSourceState
  public var members: [RoomMember]

  public init(
    id: RoomID,
    name: String,
    coordinatorID: MemberID,
    coordinatorTerm: UInt64 = 1,
    revision: UInt64 = 0,
    streamGeneration: UInt64 = 0,
    audioSource: AudioSourceState = .idle,
    members: [RoomMember]
  ) {
    self.id = id
    self.name = Self.clean(name)
    self.coordinatorID = coordinatorID
    self.coordinatorTerm = max(1, coordinatorTerm)
    self.revision = revision
    self.streamGeneration = streamGeneration
    self.audioSource = audioSource
    self.members = Self.canonical(members)
  }

  public var sourceMember: RoomMember? {
    guard let sourceID = audioSource.memberID else { return nil }
    return members.first { $0.id == sourceID }
  }

  public func contains(_ memberID: MemberID) -> Bool {
    members.contains { $0.id == memberID }
  }

  mutating func replaceMembers(_ newMembers: [RoomMember]) {
    members = Self.canonical(newMembers)
  }

  mutating func rename(to newName: String) {
    name = Self.clean(newName)
  }

  private static func clean(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Office Room" : String(trimmed.prefix(64))
  }

  private static func canonical(_ members: [RoomMember]) -> [RoomMember] {
    Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
      .values.sorted { $0.id < $1.id }
  }
}

public struct RoomDescriptor: Identifiable, Codable, Hashable, Sendable {
  public var id: RoomID
  public var name: String
  public var memberCount: Int
  public var sourceName: String?
  public var coordinatorID: MemberID
  public var coordinatorTerm: UInt64
  public var controlProtocolVersion: UInt16
  public var audioProtocolVersion: UInt8

  public init(
    id: RoomID,
    name: String,
    memberCount: Int,
    sourceName: String?,
    coordinatorID: MemberID,
    coordinatorTerm: UInt64,
    controlProtocolVersion: UInt16,
    audioProtocolVersion: UInt8 = ZeroSoundProtocol.audioVersion
  ) {
    self.id = id
    self.name = name
    self.memberCount = memberCount
    self.sourceName = sourceName
    self.coordinatorID = coordinatorID
    self.coordinatorTerm = coordinatorTerm
    self.controlProtocolVersion = controlProtocolVersion
    self.audioProtocolVersion = audioProtocolVersion
  }

  public init(snapshot: RoomSnapshot) {
    id = snapshot.id
    name = snapshot.name
    memberCount = snapshot.members.count
    sourceName = snapshot.sourceMember?.name
    coordinatorID = snapshot.coordinatorID
    coordinatorTerm = snapshot.coordinatorTerm
    controlProtocolVersion = ZeroSoundProtocol.controlVersion
    audioProtocolVersion = ZeroSoundProtocol.audioVersion
  }

  public var isCompatible: Bool {
    controlProtocolVersion == ZeroSoundProtocol.controlVersion
      && audioProtocolVersion == ZeroSoundProtocol.audioVersion
  }
}

public enum MembershipState: Equatable, Sendable {
  case discovering
  case outsideRoom
  case creating(RoomID)
  case joining(RoomID)
  case inRoom(RoomSnapshot)
  case reconnecting(RoomID)
  case leaving(RoomID)
}

public enum RoomTransitionError: Error, Equatable, LocalizedError, Sendable {
  case invalidMembershipTransition
  case wrongRoom
  case staleCoordinatorTerm
  case memberNotFound
  case roomFull
  case sourceAlreadyAssigned
  case sourceNotAssigned
  case unauthorizedSource

  public var errorDescription: String? {
    switch self {
    case .invalidMembershipTransition: "That room action is not valid right now."
    case .wrongRoom: "The message belongs to a different room."
    case .staleCoordinatorTerm: "Ignored stale coordinator state."
    case .memberNotFound: "That Mac is no longer in the room."
    case .roomFull: "This room already has eight Macs."
    case .sourceAlreadyAssigned: "Another Mac is already preparing audio."
    case .sourceNotAssigned: "The room has no active audio source."
    case .unauthorizedSource: "Only the assigned Mac may publish this stream."
    }
  }
}

public struct MembershipStateMachine: Sendable {
  public private(set) var state: MembershipState

  public init(state: MembershipState = .discovering) { self.state = state }

  public mutating func discoveryReady() throws {
    guard case .discovering = state else { throw RoomTransitionError.invalidMembershipTransition }
    state = .outsideRoom
  }

  public mutating func beginCreate(roomID: RoomID) throws {
    guard case .outsideRoom = state else { throw RoomTransitionError.invalidMembershipTransition }
    state = .creating(roomID)
  }

  public mutating func beginJoin(roomID: RoomID) throws {
    guard case .outsideRoom = state else { throw RoomTransitionError.invalidMembershipTransition }
    state = .joining(roomID)
  }

  public mutating func joined(_ snapshot: RoomSnapshot) throws {
    switch state {
    case .creating(let id) where id == snapshot.id,
      .joining(let id) where id == snapshot.id,
      .reconnecting(let id) where id == snapshot.id:
      state = .inRoom(snapshot)
    default:
      throw RoomTransitionError.invalidMembershipTransition
    }
  }

  public mutating func apply(_ snapshot: RoomSnapshot) throws {
    guard case .inRoom(let current) = state, current.id == snapshot.id else {
      throw RoomTransitionError.wrongRoom
    }
    guard snapshot.coordinatorTerm >= current.coordinatorTerm else {
      throw RoomTransitionError.staleCoordinatorTerm
    }
    guard
      snapshot.coordinatorTerm > current.coordinatorTerm || snapshot.revision >= current.revision
    else { throw RoomTransitionError.staleCoordinatorTerm }
    state = .inRoom(snapshot)
  }

  public mutating func connectionLost() throws {
    guard case .inRoom(let snapshot) = state else {
      throw RoomTransitionError.invalidMembershipTransition
    }
    state = .reconnecting(snapshot.id)
  }

  public mutating func beginLeave() throws {
    switch state {
    case .inRoom(let snapshot): state = .leaving(snapshot.id)
    case .reconnecting(let id): state = .leaving(id)
    default: throw RoomTransitionError.invalidMembershipTransition
    }
  }

  public mutating func left() throws {
    guard case .leaving = state else { throw RoomTransitionError.invalidMembershipTransition }
    state = .outsideRoom
  }
}
