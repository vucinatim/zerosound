import Foundation
import Testing

@testable import ZeroSoundCore

@Test(.timeLimit(.minutes(1)))
func realUDPTransportJoinsAndPublishesAuthoritativeRoster() async throws {
  let coordinatorID = MemberID()
  let joiningID = MemberID()
  let initial = RoomSnapshot(
    id: RoomID(),
    name: "Transport Test",
    coordinatorID: coordinatorID,
    members: [RoomMember(id: coordinatorID, name: "Coordinator", connection: .ready)]
  )
  let coordinator = RoomCoordinator(
    snapshot: initial,
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let connection = RoomConnection(
    localMember: RoomMember(id: joiningID, name: "Joining Mac"))

  let (snapshots, continuation) = AsyncStream<RoomSnapshot>.makeStream()
  connection.onSnapshot = { continuation.yield($0) }
  coordinator.onReady = { room in connection.connect(to: room) }
  try coordinator.start()

  let joined = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      for await snapshot in snapshots {
        if snapshot.members.map(\.id).contains(joiningID) { return true }
      }
      return false
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return false
    }
    let result = await group.next() ?? false
    group.cancelAll()
    return result
  }
  continuation.finish()
  #expect(joined, "joined roster delivered over UDP")

  connection.disconnect(notify: true)
  coordinator.stop()
}

@Test(.timeLimit(.minutes(1)))
func departingPeerCannotPolluteCoordinatorStatusWithLateCommands() async throws {
  let coordinatorID = MemberID()
  let departingID = MemberID()
  let initial = RoomSnapshot(
    id: RoomID(),
    name: "Departure Test",
    coordinatorID: coordinatorID,
    members: [RoomMember(id: coordinatorID, name: "Coordinator", connection: .ready)]
  )
  let coordinator = RoomCoordinator(
    snapshot: initial,
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let connection = RoomConnection(
    localMember: RoomMember(id: departingID, name: "Departing Mac"))
  let (snapshots, snapshotContinuation) = AsyncStream<RoomSnapshot>.makeStream()
  let (errors, errorContinuation) = AsyncStream<String>.makeStream()

  coordinator.onSnapshot = { snapshotContinuation.yield($0) }
  coordinator.onError = { errorContinuation.yield($0) }
  coordinator.onReady = { room in connection.connect(to: room) }
  try coordinator.start()

  let joined = await nextSnapshot(in: snapshots) { $0.contains(departingID) }
  #expect(joined != nil)
  connection.send(.leave(departingID))
  let departed = await nextSnapshot(in: snapshots) { !$0.contains(departingID) }
  #expect(departed != nil)

  let lateError = await withTaskGroup(of: String?.self) { group in
    group.addTask {
      for await error in errors { return error }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(2))
      return nil
    }
    let result = await group.next() ?? nil
    group.cancelAll()
    return result
  }
  #expect(lateError == nil)

  connection.disconnect()
  coordinator.stop()
  snapshotContinuation.finish()
  errorContinuation.finish()
}

@Test(.timeLimit(.minutes(1)))
func realUDPTransportSupportsEightMembersSourceTransferAndCoordinatorExit() async throws {
  let coordinatorID = MemberID()
  let roomID = RoomID()
  let initial = RoomSnapshot(
    id: roomID,
    name: "Eight Mac Test",
    coordinatorID: coordinatorID,
    members: [RoomMember(id: coordinatorID, name: "Mac 1", connection: .ready)]
  )
  let coordinator = RoomCoordinator(
    snapshot: initial,
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let memberIDs = (2...8).map { _ in MemberID() }
  let connections = zip(memberIDs, 2...8).map { memberID, number in
    RoomConnection(localMember: RoomMember(id: memberID, name: "Mac \(number)"))
  }
  let (coordinatorSnapshots, coordinatorSnapshotContinuation) =
    AsyncStream<RoomSnapshot>.makeStream()
  let (observerSnapshots, observerSnapshotContinuation) =
    AsyncStream<RoomSnapshot>.makeStream()
  let (audioPackets, audioContinuation) = AsyncStream<AudioPacket>.makeStream()

  coordinator.onSnapshot = { coordinatorSnapshotContinuation.yield($0) }
  coordinator.onAudio = { audioContinuation.yield($0) }
  connections.last?.onSnapshot = { observerSnapshotContinuation.yield($0) }

  for (index, connection) in connections.enumerated() where index < 2 {
    let sourceID = memberIDs[index]
    connection.onEvent = { event in
      switch event {
      case .sourceAssignment(let memberID, let generation) where memberID == sourceID:
        connection.send(.sourcePrimed(memberID: sourceID, generation: generation))
      case .streamStart(let memberID, let generation, _) where memberID == sourceID:
        connection.send(.sourceLive(memberID: sourceID, generation: generation))
      default: break
      }
    }
  }

  coordinator.onReady = { room in
    for connection in connections { connection.connect(to: room) }
  }
  try coordinator.start()

  let fullRoster = await nextSnapshot(in: coordinatorSnapshots) { $0.members.count == 8 }
  #expect(fullRoster?.members.count == 8)

  let firstSource = memberIDs[0]
  connections[0].send(.requestSource(firstSource))
  let firstLive = await nextSnapshot(in: coordinatorSnapshots) {
    $0.audioSource == .live(firstSource)
  }
  let firstGeneration = try #require(firstLive?.streamGeneration)
  let firstPacket = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 1_000_000_000,
    sampleRate: 48_000,
    streamGeneration: firstGeneration,
    sourceID: firstSource,
    floatSamples: [0.1, 0.1]
  )
  connections[0].sendAudio(firstPacket)
  let routedFirstPacket = await nextAudioPacket(in: audioPackets)
  #expect(routedFirstPacket == firstPacket)

  let secondSource = memberIDs[1]
  connections[1].send(.requestSource(secondSource))
  let secondLive = await nextSnapshot(in: coordinatorSnapshots) {
    $0.audioSource == .live(secondSource)
  }
  let secondGeneration = try #require(secondLive?.streamGeneration)
  #expect(secondGeneration > firstGeneration)
  connections[0].sendAudio(firstPacket)
  try? await Task.sleep(for: .milliseconds(40))
  #expect(coordinator.snapshot.streamGeneration == secondGeneration)

  coordinator.submitLocal(.leave(coordinatorID))
  let replacement = await nextSnapshot(in: observerSnapshots) {
    $0.coordinatorID == memberIDs.min() && $0.coordinatorTerm == 2
  }
  #expect(replacement?.id == roomID)
  #expect(replacement?.members.count == 7)

  for connection in connections { connection.disconnect() }
  coordinator.stop()
  coordinatorSnapshotContinuation.finish()
  observerSnapshotContinuation.finish()
  audioContinuation.finish()
}

private func nextSnapshot(
  in stream: AsyncStream<RoomSnapshot>,
  matching predicate: @escaping @Sendable (RoomSnapshot) -> Bool
) async -> RoomSnapshot? {
  await withTaskGroup(of: RoomSnapshot?.self) { group in
    group.addTask {
      for await snapshot in stream where predicate(snapshot) { return snapshot }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return nil
    }
    let result = await group.next() ?? nil
    group.cancelAll()
    return result
  }
}

private func nextAudioPacket(in stream: AsyncStream<AudioPacket>) async -> AudioPacket? {
  await withTaskGroup(of: AudioPacket?.self) { group in
    group.addTask {
      for await packet in stream { return packet }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(5))
      return nil
    }
    let result = await group.next() ?? nil
    group.cancelAll()
    return result
  }
}
