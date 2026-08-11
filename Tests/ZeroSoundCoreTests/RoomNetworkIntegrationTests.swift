import Foundation
import Testing

@testable import ZeroSoundCore

@Test(.timeLimit(.minutes(1)))
func splitTransportJoinsAndPublishesAuthoritativeRoster() async throws {
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
  #expect(joined, "joined roster delivered over framed TCP after UDP registration")

  connection.disconnect(notify: true)
  coordinator.stop()
}

@Test func nonAuthoritativeCoordinatorCannotStartACompetingSession() {
  let authoritativeID = MemberID()
  let otherID = MemberID()
  let coordinator = RoomCoordinator(
    snapshot: RoomSnapshot(
      id: RoomID(),
      name: "Authority Test",
      coordinatorID: authoritativeID,
      members: [
        RoomMember(id: authoritativeID, name: "Authority", connection: .ready),
        RoomMember(id: otherID, name: "Other", connection: .ready),
      ]
    ),
    localMemberID: otherID,
    advertisesRoom: false
  )

  #expect(throws: RoomTransitionError.invalidMembershipTransition) {
    try coordinator.start()
  }
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
func abruptControlDisconnectRemovesTheMemberAuthoritatively() async throws {
  let coordinatorID = MemberID()
  let memberID = MemberID()
  let coordinator = RoomCoordinator(
    snapshot: RoomSnapshot(
      id: RoomID(),
      name: "Abrupt Disconnect Test",
      coordinatorID: coordinatorID,
      members: [RoomMember(id: coordinatorID, name: "Coordinator", connection: .ready)]
    ),
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let connection = RoomConnection(localMember: RoomMember(id: memberID, name: "Member"))
  let (snapshots, continuation) = AsyncStream<RoomSnapshot>.makeStream()
  coordinator.onSnapshot = { continuation.yield($0) }
  coordinator.onReady = { connection.connect(to: $0) }
  try coordinator.start()

  #expect(await nextSnapshot(in: snapshots) { $0.contains(memberID) } != nil)
  connection.disconnect()
  #expect(await nextSnapshot(in: snapshots) { !$0.contains(memberID) } != nil)

  coordinator.stop()
  continuation.finish()
}

@Test(.timeLimit(.minutes(1)))
func registeredMemberCanReplaceOnlyItsAudioPathWithoutRejoiningTheRoom() async throws {
  let coordinatorID = MemberID()
  let memberID = MemberID()
  let coordinator = RoomCoordinator(
    snapshot: RoomSnapshot(
      id: RoomID(),
      name: "Audio Path Recovery Test",
      coordinatorID: coordinatorID,
      members: [RoomMember(id: coordinatorID, name: "Coordinator", connection: .ready)]
    ),
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let connection = RoomConnection(localMember: RoomMember(id: memberID, name: "Member"))
  let (recovered, recoveredContinuation) = AsyncStream<Bool>.makeStream()
  let probe = AudioRefreshProbe()

  connection.onTransportDiagnostics = { diagnostics in
    switch probe.observe(diagnostics) {
    case .requestReplacement:
      connection.refreshAudioPath()
    case .recovered:
      recoveredContinuation.yield(true)
    case .none:
      break
    }
  }
  coordinator.onReady = { connection.connect(to: $0) }
  try coordinator.start()

  #expect(await nextValue(in: recovered) { $0 } == true)
  let finalSnapshot = coordinator.snapshot
  #expect(finalSnapshot.members.map(\.id).sorted() == [coordinatorID, memberID].sorted())
  #expect(finalSnapshot.coordinatorTerm == 1)
  #expect(finalSnapshot.streamGeneration == 0)

  connection.disconnect()
  coordinator.stop()
  recoveredContinuation.finish()
}

@Test(.timeLimit(.minutes(1)))
func splitTransportSupportsEightMembersSourceTransferAndCoordinatorExit() async throws {
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

@Test(.timeLimit(.minutes(1)))
func promotedCoordinatorAcceptsSurvivorsAndRestartsAudioOnTheNewTerm() async throws {
  let oldCoordinatorID = MemberID(
    UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
  let successorID = MemberID(
    UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  let receiverID = MemberID(
    UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
  let roomID = RoomID()
  let oldCoordinator = RoomCoordinator(
    snapshot: RoomSnapshot(
      id: roomID,
      name: "Coordinator Recovery Test",
      coordinatorID: oldCoordinatorID,
      members: [
        RoomMember(id: oldCoordinatorID, name: "Old Coordinator", connection: .ready)
      ]
    ),
    localMemberID: oldCoordinatorID,
    advertisesRoom: false
  )
  let successorConnection = RoomConnection(
    localMember: RoomMember(id: successorID, name: "Successor"))
  let receiverConnection = RoomConnection(
    localMember: RoomMember(id: receiverID, name: "Receiver"))
  let (oldSnapshots, oldSnapshotContinuation) = AsyncStream<RoomSnapshot>.makeStream()
  let (receiverSnapshots, receiverSnapshotContinuation) = AsyncStream<RoomSnapshot>.makeStream()
  let (receivedAudio, audioContinuation) = AsyncStream<AudioPacket>.makeStream()

  oldCoordinator.onSnapshot = { oldSnapshotContinuation.yield($0) }
  receiverConnection.onSnapshot = { receiverSnapshotContinuation.yield($0) }
  receiverConnection.onAudio = { packet, _ in audioContinuation.yield(packet) }
  oldCoordinator.onReady = { room in
    successorConnection.connect(to: room)
    receiverConnection.connect(to: room)
  }
  try oldCoordinator.start()
  #expect(await nextSnapshot(in: oldSnapshots) { $0.members.count == 3 } != nil)

  oldCoordinator.submitLocal(.leave(oldCoordinatorID))
  let promotedSnapshot = try #require(
    await nextSnapshot(in: receiverSnapshots) {
      $0.coordinatorID == successorID && $0.coordinatorTerm == 2
    })
  #expect(promotedSnapshot.id == roomID)
  #expect(promotedSnapshot.audioSource == .idle)
  oldCoordinator.stop()
  successorConnection.disconnect()
  receiverConnection.disconnect()
  let (clockSamples, clockContinuation) = AsyncStream<Int>.makeStream()
  receiverConnection.onClock = { _, _, samples, _ in clockContinuation.yield(samples) }

  let promotedCoordinator = RoomCoordinator(
    snapshot: promotedSnapshot,
    localMemberID: successorID,
    advertisesRoom: false
  )
  promotedCoordinator.onEvent = { event in
    switch event {
    case .sourceAssignment(let memberID, let generation) where memberID == successorID:
      promotedCoordinator.submitLocal(
        .sourcePrimed(memberID: successorID, generation: generation))
    case .streamStart(let memberID, let generation, _) where memberID == successorID:
      promotedCoordinator.submitLocal(.sourceLive(memberID: successorID, generation: generation))
    default:
      break
    }
  }
  promotedCoordinator.onReady = { room in receiverConnection.connect(to: room) }
  try promotedCoordinator.start()

  let rejoined = try #require(
    await nextSnapshot(in: receiverSnapshots) {
      $0.coordinatorID == successorID && $0.coordinatorTerm == 2 && $0.contains(receiverID)
        && $0.revision > promotedSnapshot.revision
    })
  #expect(await nextValue(in: clockSamples) { $0 >= 4 } != nil)
  promotedCoordinator.submitLocal(.requestSource(successorID))
  let live = try #require(
    await nextSnapshot(in: receiverSnapshots) { $0.audioSource == .live(successorID) })
  #expect(live.streamGeneration > rejoined.streamGeneration)

  let packet = AudioPacket(
    sequence: 1,
    presentationNanoseconds: MonotonicTime.nowNanoseconds() + 300_000_000,
    sampleRate: 48_000,
    streamGeneration: live.streamGeneration,
    sourceID: successorID,
    floatSamples: [0.25, 0.25]
  )
  promotedCoordinator.broadcastAudio(packet)
  #expect(await nextAudioPacket(in: receivedAudio) == packet)

  successorConnection.disconnect()
  receiverConnection.disconnect()
  promotedCoordinator.stop()
  oldSnapshotContinuation.finish()
  receiverSnapshotContinuation.finish()
  audioContinuation.finish()
  clockContinuation.finish()
}

@Test(.timeLimit(.minutes(1)))
func liveAudioSurvivesAnUnrelatedMemberJoiningAndLeaving() async throws {
  let coordinatorID = MemberID()
  let receiverID = MemberID()
  let transientID = MemberID()
  let initial = RoomSnapshot(
    id: RoomID(),
    name: "Stable Stream Test",
    coordinatorID: coordinatorID,
    members: [RoomMember(id: coordinatorID, name: "Source", connection: .ready)]
  )
  let coordinator = RoomCoordinator(
    snapshot: initial,
    localMemberID: coordinatorID,
    advertisesRoom: false
  )
  let receiver = RoomConnection(
    localMember: RoomMember(id: receiverID, name: "Receiver"))
  let transient = RoomConnection(
    localMember: RoomMember(id: transientID, name: "Transient"))
  let (snapshots, snapshotContinuation) = AsyncStream<RoomSnapshot>.makeStream()
  let (clockSamples, clockContinuation) = AsyncStream<Int>.makeStream()
  let (receivedAudio, audioContinuation) = AsyncStream<AudioPacket>.makeStream()
  let (readyRooms, readyContinuation) = AsyncStream<DiscoveredRoom>.makeStream()

  coordinator.onSnapshot = { snapshotContinuation.yield($0) }
  coordinator.onEvent = { event in
    switch event {
    case .sourceAssignment(let memberID, let generation) where memberID == coordinatorID:
      coordinator.submitLocal(.sourcePrimed(memberID: coordinatorID, generation: generation))
    case .streamStart(let memberID, let generation, _) where memberID == coordinatorID:
      coordinator.submitLocal(.sourceLive(memberID: coordinatorID, generation: generation))
    default:
      break
    }
  }
  receiver.onClock = { _, _, samples, _ in clockContinuation.yield(samples) }
  receiver.onAudio = { packet, _ in audioContinuation.yield(packet) }
  coordinator.onReady = { room in
    readyContinuation.yield(room)
    receiver.connect(to: room)
  }
  try coordinator.start()
  let localRoom = try #require(await nextValue(in: readyRooms) { _ in true })

  _ = await nextSnapshot(in: snapshots) { $0.contains(receiverID) }
  coordinator.submitLocal(.requestSource(coordinatorID))
  let live = try #require(
    await nextSnapshot(in: snapshots) { $0.audioSource == .live(coordinatorID) })
  let locked = await nextValue(in: clockSamples) { $0 >= 4 }
  #expect(locked != nil)

  let firstPacket = AudioPacket(
    sequence: 1,
    presentationNanoseconds: MonotonicTime.nowNanoseconds() + 300_000_000,
    sampleRate: 48_000,
    streamGeneration: live.streamGeneration,
    sourceID: coordinatorID,
    floatSamples: [0.1, 0.1]
  )
  coordinator.broadcastAudio(firstPacket)
  #expect(await nextAudioPacket(in: receivedAudio) == firstPacket)

  transient.connect(to: localRoom)
  let joined = try #require(await nextSnapshot(in: snapshots) { $0.contains(transientID) })
  #expect(joined.streamGeneration == live.streamGeneration)
  #expect(joined.audioSource == live.audioSource)
  transient.disconnect(notify: true)
  let left = try #require(await nextSnapshot(in: snapshots) { !$0.contains(transientID) })
  #expect(left.streamGeneration == live.streamGeneration)
  #expect(left.audioSource == live.audioSource)

  let secondPacket = AudioPacket(
    sequence: 2,
    presentationNanoseconds: MonotonicTime.nowNanoseconds() + 300_000_000,
    sampleRate: 48_000,
    streamGeneration: live.streamGeneration,
    sourceID: coordinatorID,
    floatSamples: [0.2, 0.2]
  )
  coordinator.broadcastAudio(secondPacket)
  #expect(await nextAudioPacket(in: receivedAudio) == secondPacket)

  receiver.disconnect()
  transient.disconnect()
  coordinator.stop()
  snapshotContinuation.finish()
  clockContinuation.finish()
  audioContinuation.finish()
  readyContinuation.finish()
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

private final class AudioRefreshProbe: @unchecked Sendable {
  enum Action {
    case none
    case requestReplacement
    case recovered
  }

  private let lock = NSLock()
  private var sawInitialReady = false
  private var sawReplacementRegistration = false

  func observe(_ diagnostics: TransportDiagnostics) -> Action {
    lock.lock()
    defer { lock.unlock() }

    if !sawInitialReady, diagnostics.audio == .ready {
      sawInitialReady = true
      return .requestReplacement
    }
    if sawInitialReady, diagnostics.audio == .registering {
      sawReplacementRegistration = true
      return .none
    }
    if sawReplacementRegistration, diagnostics.audio == .ready {
      sawReplacementRegistration = false
      return .recovered
    }
    return .none
  }
}

private func nextValue<Value: Sendable>(
  in stream: AsyncStream<Value>,
  matching predicate: @escaping @Sendable (Value) -> Bool
) async -> Value? {
  await withTaskGroup(of: Value?.self) { group in
    group.addTask {
      for await value in stream where predicate(value) { return value }
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
