import Foundation

public enum RoomCommand: Codable, Equatable, Sendable {
  case join(RoomMember)
  case renameRoom(memberID: MemberID, name: String)
  case leave(MemberID)
  case heartbeat(
    memberID: MemberID,
    health: PlaybackHealth,
    roundTripNanoseconds: UInt64?,
    audioLevel: Float
  )
  case requestSource(MemberID)
  case sourcePrimed(memberID: MemberID, generation: UInt64)
  case sourceLive(memberID: MemberID, generation: UInt64)
  case releaseSource(MemberID)
  case sourceStopped(memberID: MemberID, generation: UInt64)
  case sourceFailed(memberID: MemberID, generation: UInt64, reason: String)
  case claimCoordinator(memberID: MemberID, term: UInt64)
}

public enum RoomEvent: Codable, Equatable, Sendable {
  case memberAccepted(RoomSnapshot)
  case memberRejected(memberID: MemberID, reason: String)
  case snapshot(RoomSnapshot)
  case sourceAssignment(memberID: MemberID, generation: UInt64)
  case streamStart(memberID: MemberID, generation: UInt64, anchorNanoseconds: UInt64)
  case streamStop(generation: UInt64, acknowledgement: MemberID?)
  case coordinatorChanged(memberID: MemberID, term: UInt64)
  case error(String)
}

/// The authoritative, Foundation-only room reducer. Networking transports commands to the
/// coordinator; it does not duplicate these transition rules.
public struct RoomStateMachine: Sendable {
  public private(set) var snapshot: RoomSnapshot

  public init(snapshot: RoomSnapshot) { self.snapshot = snapshot }

  public mutating func handle(
    _ command: RoomCommand,
    nowNanoseconds: UInt64 = 0
  ) throws -> [RoomEvent] {
    switch command {
    case .join(var member):
      guard snapshot.contains(member.id) || snapshot.members.count < 8 else {
        throw RoomTransitionError.roomFull
      }
      if let existing = snapshot.members.first(where: { $0.id == member.id }) {
        member.worstRoundTripNanoseconds = Self.maximum(
          existing.worstRoundTripNanoseconds,
          member.worstRoundTripNanoseconds
        )
      }
      member.connection = .ready
      var members = snapshot.members.filter { $0.id != member.id }
      members.append(member)
      snapshot.replaceMembers(members)
      return commit([.memberAccepted(snapshot), .snapshot(snapshot)])

    case .renameRoom(let memberID, let name):
      guard snapshot.contains(memberID) else { throw RoomTransitionError.memberNotFound }
      snapshot.rename(to: name)
      return commit([.snapshot(snapshot)])

    case .leave(let memberID):
      guard snapshot.contains(memberID) else { throw RoomTransitionError.memberNotFound }
      let coordinatorDeparted = snapshot.coordinatorID == memberID
      snapshot.replaceMembers(snapshot.members.filter { $0.id != memberID })
      var events: [RoomEvent] = []
      if snapshot.audioSource.memberID == memberID
        || (coordinatorDeparted && snapshot.audioSource != .idle)
      {
        snapshot.streamGeneration &+= 1
        snapshot.audioSource = .idle
        events.append(.streamStop(generation: snapshot.streamGeneration, acknowledgement: nil))
      }
      if coordinatorDeparted, let successor = Self.successor(in: snapshot.members) {
        snapshot.coordinatorID = successor
        snapshot.coordinatorTerm &+= 1
        events.append(
          .coordinatorChanged(memberID: successor, term: snapshot.coordinatorTerm))
      }
      events.append(.snapshot(snapshot))
      return commit(events)

    case .heartbeat(let memberID, let health, let roundTrip, let audioLevel):
      guard let index = snapshot.members.firstIndex(where: { $0.id == memberID }) else {
        throw RoomTransitionError.memberNotFound
      }
      snapshot.members[index].connection = .ready
      snapshot.members[index].playbackHealth = health
      snapshot.members[index].roundTripNanoseconds = roundTrip
      snapshot.members[index].worstRoundTripNanoseconds = Self.maximum(
        snapshot.members[index].worstRoundTripNanoseconds,
        roundTrip
      )
      snapshot.members[index].audioLevel = min(1, max(0, audioLevel))
      return commit([.snapshot(snapshot)])

    case .requestSource(let memberID):
      guard snapshot.contains(memberID) else { throw RoomTransitionError.memberNotFound }
      switch snapshot.audioSource {
      case .assigning, .priming, .stopping:
        throw RoomTransitionError.sourceAlreadyAssigned
      case .idle, .live:
        snapshot.streamGeneration &+= 1
        snapshot.audioSource = .assigning(memberID)
        return commit([
          .streamStop(generation: snapshot.streamGeneration, acknowledgement: nil),
          .sourceAssignment(memberID: memberID, generation: snapshot.streamGeneration),
          .snapshot(snapshot),
        ])
      }

    case .sourcePrimed(let memberID, let generation):
      try validateSource(memberID, generation: generation, expected: snapshot.audioSource)
      guard case .assigning = snapshot.audioSource else {
        throw RoomTransitionError.unauthorizedSource
      }
      snapshot.audioSource = .priming(memberID)
      let anchor = nowNanoseconds &+ 300_000_000
      return commit([
        .streamStart(memberID: memberID, generation: generation, anchorNanoseconds: anchor),
        .snapshot(snapshot),
      ])

    case .sourceLive(let memberID, let generation):
      try validateSource(memberID, generation: generation, expected: snapshot.audioSource)
      guard case .priming = snapshot.audioSource else {
        throw RoomTransitionError.unauthorizedSource
      }
      snapshot.audioSource = .live(memberID)
      return commit([.snapshot(snapshot)])

    case .releaseSource(let memberID):
      guard snapshot.audioSource.memberID == memberID else {
        throw RoomTransitionError.unauthorizedSource
      }
      snapshot.audioSource = .stopping(memberID)
      return commit([
        .streamStop(generation: snapshot.streamGeneration, acknowledgement: memberID),
        .snapshot(snapshot),
      ])

    case .sourceStopped(let memberID, let generation),
      .sourceFailed(let memberID, let generation, _):
      try validateSource(memberID, generation: generation, expected: snapshot.audioSource)
      snapshot.audioSource = .idle
      return commit([
        .streamStop(generation: generation, acknowledgement: nil),
        .snapshot(snapshot),
      ])

    case .claimCoordinator(let memberID, let term):
      guard snapshot.contains(memberID) else { throw RoomTransitionError.memberNotFound }
      guard term > snapshot.coordinatorTerm else { throw RoomTransitionError.staleCoordinatorTerm }
      guard memberID == Self.successor(in: snapshot.members) else {
        throw RoomTransitionError.invalidMembershipTransition
      }
      snapshot.coordinatorID = memberID
      snapshot.coordinatorTerm = term
      return commit([.coordinatorChanged(memberID: memberID, term: term), .snapshot(snapshot)])
    }
  }

  public static func successor(in members: [RoomMember]) -> MemberID? {
    members.map(\.id).min()
  }

  public static func successor(
    afterRemoving departed: MemberID,
    from members: [RoomMember]
  ) -> MemberID? {
    successor(in: members.filter { $0.id != departed })
  }

  private static func maximum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
    case (.some(let value), .none), (.none, .some(let value)): value
    case (.none, .none): nil
    }
  }

  private func validateSource(
    _ memberID: MemberID,
    generation: UInt64,
    expected: AudioSourceState
  ) throws {
    guard generation == snapshot.streamGeneration, expected.memberID == memberID else {
      throw RoomTransitionError.unauthorizedSource
    }
  }

  private mutating func commit(_ events: [RoomEvent]) -> [RoomEvent] {
    snapshot.revision &+= 1
    return events.map { event in
      switch event {
      case .memberAccepted: .memberAccepted(snapshot)
      case .snapshot: .snapshot(snapshot)
      default: event
      }
    }
  }
}

struct AudioPacketFence: Sendable {
  static func accepts(_ packet: AudioPacket, snapshot: RoomSnapshot) -> Bool {
    guard case .live(let sourceID) = snapshot.audioSource else { return false }
    return packet.sourceID == sourceID && packet.streamGeneration == snapshot.streamGeneration
  }
}
