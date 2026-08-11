import Foundation
@preconcurrency import Network
import Testing

@testable import ZeroSoundCore

private let roomID = RoomID(UUID(uuidString: "00000000-0000-0000-0000-000000000100")!)
private let memberA = MemberID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
private let memberB = MemberID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
private let memberC = MemberID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

private func member(_ id: MemberID, _ name: String) -> RoomMember {
  RoomMember(id: id, name: name, connection: .ready)
}

private func snapshot(
  members: [RoomMember] = [member(memberA, "A")],
  source: AudioSourceState = .idle,
  generation: UInt64 = 0,
  term: UInt64 = 1
) -> RoomSnapshot {
  RoomSnapshot(
    id: roomID,
    name: "Office Room",
    coordinatorID: memberA,
    coordinatorTerm: term,
    streamGeneration: generation,
    audioSource: source,
    members: members
  )
}

@Test func membershipLifecycleIsExplicit() throws {
  var machine = MembershipStateMachine()
  try machine.discoveryReady()
  #expect(machine.state == .outsideRoom)
  try machine.beginCreate(roomID: roomID)
  #expect(machine.state == .creating(roomID))
  let room = snapshot()
  try machine.joined(room)
  #expect(machine.state == .inRoom(room))
  try machine.connectionLost()
  #expect(machine.state == .reconnecting(roomID))
  try machine.joined(room)
  try machine.beginLeave()
  #expect(machine.state == .leaving(roomID))
  try machine.left()
  #expect(machine.state == .outsideRoom)
}

@Test func transportJoinLifecycleRequiresControlAndAudioReadiness() throws {
  var machine = JoinStateMachine()

  try machine.apply(.begin)
  #expect(machine.phase == .connectingControl)
  try machine.apply(.controlReady)
  #expect(machine.phase == .awaitingAudioOffer)
  try machine.apply(.audioOffered)
  #expect(machine.phase == .registeringAudio)
  try machine.apply(.accepted)
  #expect(machine.isJoined)
  try machine.apply(.close)
  #expect(machine.phase == .closed)
}

@Test func transportJoinLifecycleRejectsAcceptanceBeforeAudioRegistration() throws {
  var machine = JoinStateMachine()
  try machine.apply(.begin)
  try machine.apply(.controlReady)

  #expect(throws: JoinStateError.self) {
    try machine.apply(.accepted)
  }
}

@Test func membershipRejectsInvalidAndWrongRoomTransitions() throws {
  var machine = MembershipStateMachine(state: .outsideRoom)
  #expect(throws: RoomTransitionError.invalidMembershipTransition) {
    try machine.connectionLost()
  }
  try machine.beginJoin(roomID: roomID)
  let otherRoom = RoomSnapshot(
    id: RoomID(), name: "Other", coordinatorID: memberA, members: [member(memberA, "A")])
  #expect(throws: RoomTransitionError.invalidMembershipTransition) {
    try machine.joined(otherRoom)
  }
}

@Test func snapshotCanonicalizesDuplicateStableMembers() {
  let old = RoomMember(id: memberB, name: "Old")
  let newest = RoomMember(id: memberB, name: "Newest", connection: .ready)
  let room = snapshot(members: [old, member(memberA, "A"), newest])
  #expect(room.members.count == 2)
  #expect(room.members.first(where: { $0.id == memberB })?.name == "Newest")
}

@Test func joiningTwiceUpdatesInsteadOfDuplicatingMember() throws {
  var room = RoomStateMachine(snapshot: snapshot())
  _ = try room.handle(.join(member(memberB, "B")))
  _ = try room.handle(.join(member(memberB, "B renamed")))
  #expect(room.snapshot.members.count == 2)
  #expect(room.snapshot.members.first(where: { $0.id == memberB })?.name == "B renamed")
}

@Test func heartbeatRetainsWorstRoundTripAcrossImprovementAndReconnect() throws {
  var room = RoomStateMachine(
    snapshot: snapshot(members: [member(memberA, "A"), member(memberB, "B")]))

  _ = try room.handle(
    .heartbeat(
      memberID: memberB,
      health: PlaybackHealth(),
      roundTripNanoseconds: 42_000_000,
      audioLevel: 0
    ))
  _ = try room.handle(
    .heartbeat(
      memberID: memberB,
      health: PlaybackHealth(),
      roundTripNanoseconds: 8_000_000,
      audioLevel: 0
    ))

  var measured = try #require(room.snapshot.members.first { $0.id == memberB })
  #expect(measured.roundTripNanoseconds == 8_000_000)
  #expect(measured.worstRoundTripNanoseconds == 42_000_000)

  _ = try room.handle(.join(member(memberB, "B reconnected")))
  measured = try #require(room.snapshot.members.first { $0.id == memberB })
  #expect(measured.worstRoundTripNanoseconds == 42_000_000)
}

@Test func sourceAssignmentRunsScheduledStateSequence() throws {
  var room = RoomStateMachine(
    snapshot: snapshot(members: [member(memberA, "A"), member(memberB, "B")]))
  let assigning = try room.handle(.requestSource(memberB))
  #expect(room.snapshot.audioSource == .assigning(memberB))
  #expect(room.snapshot.streamGeneration == 1)
  #expect(assigning.contains(.sourceAssignment(memberID: memberB, generation: 1)))

  let priming = try room.handle(
    .sourcePrimed(memberID: memberB, generation: 1), nowNanoseconds: 10_000)
  #expect(room.snapshot.audioSource == .priming(memberB))
  #expect(
    priming.contains(
      .streamStart(memberID: memberB, generation: 1, anchorNanoseconds: 300_010_000)))

  _ = try room.handle(.sourceLive(memberID: memberB, generation: 1))
  #expect(room.snapshot.audioSource == .live(memberB))
  _ = try room.handle(.releaseSource(memberB))
  #expect(room.snapshot.audioSource == .stopping(memberB))
  _ = try room.handle(.sourceStopped(memberID: memberB, generation: 1))
  #expect(room.snapshot.audioSource == .idle)
}

@Test func sourceTakeoverFencesTheOldGenerationImmediately() throws {
  var room = RoomStateMachine(
    snapshot: snapshot(
      members: [member(memberA, "A"), member(memberB, "B")],
      source: .live(memberA),
      generation: 7
    ))
  _ = try room.handle(.requestSource(memberB))
  #expect(room.snapshot.streamGeneration == 8)
  #expect(room.snapshot.audioSource == .assigning(memberB))
  #expect(throws: RoomTransitionError.unauthorizedSource) {
    try room.handle(.sourceLive(memberID: memberA, generation: 7))
  }
}

@Test func newStreamGenerationStartsAFreshTelemetryEpoch() throws {
  let staleHealth = PlaybackHealth(
    missingPackets: 371,
    rendererUnderruns: 4,
    recentMissingPackets: 29,
    recentRendererUnderruns: 1
  )
  let measured = RoomMember(
    id: memberA,
    name: "A",
    connection: .ready,
    playbackHealth: staleHealth,
    audioLevel: 0.8
  )
  var room = RoomStateMachine(snapshot: snapshot(members: [measured]))

  _ = try room.handle(.requestSource(memberA))

  let reset = try #require(room.snapshot.members.first)
  #expect(reset.playbackHealth == PlaybackHealth())
  #expect(reset.audioLevel == 0)
}

@Test func sourceFailureReturnsRoomToIdle() throws {
  var room = RoomStateMachine(snapshot: snapshot())
  _ = try room.handle(.requestSource(memberA))
  _ = try room.handle(.sourceFailed(memberID: memberA, generation: 1, reason: "Denied"))
  #expect(room.snapshot.audioSource == .idle)
}

@Test func leavingSourceKeepsRoomAndStopsAudio() throws {
  var room = RoomStateMachine(
    snapshot: snapshot(
      members: [member(memberA, "A"), member(memberB, "B")],
      source: .live(memberB),
      generation: 4
    ))
  let events = try room.handle(.leave(memberB))
  #expect(room.snapshot.members.map(\.id) == [memberA])
  #expect(room.snapshot.audioSource == .idle)
  #expect(room.snapshot.streamGeneration == 5)
  #expect(events.contains(.streamStop(generation: 5, acknowledgement: nil)))
}

@Test func coordinatorExitElectsDeterministicSuccessorWithoutChangingRoom() throws {
  var room = RoomStateMachine(
    snapshot: snapshot(members: [member(memberC, "C"), member(memberA, "A"), member(memberB, "B")]))
  let events = try room.handle(.leave(memberA))
  #expect(room.snapshot.id == roomID)
  #expect(room.snapshot.coordinatorID == memberB)
  #expect(room.snapshot.coordinatorTerm == 2)
  #expect(events.contains(.coordinatorChanged(memberID: memberB, term: 2)))
}

@Test func staleCoordinatorStateIsRejected() throws {
  var membership = MembershipStateMachine(state: .inRoom(snapshot(term: 4)))
  #expect(throws: RoomTransitionError.staleCoordinatorTerm) {
    try membership.apply(snapshot(term: 3))
  }
}

@Test func reorderedSnapshotFromSameTermCannotRollStateBack() throws {
  var current = snapshot(term: 4)
  current.revision = 12
  var old = current
  old.revision = 11
  var membership = MembershipStateMachine(state: .inRoom(current))
  #expect(throws: RoomTransitionError.staleCoordinatorTerm) {
    try membership.apply(old)
  }
}

@Test func roomRenameIsAuthoritativeAndRoomCapacityIsBounded() throws {
  let members = (1...8).map { index in
    member(MemberID(UUID()), "Mac \(index)")
  }
  var room = RoomStateMachine(
    snapshot: RoomSnapshot(
      id: roomID,
      name: "Office Room",
      coordinatorID: members[0].id,
      members: members
    ))
  _ = try room.handle(.renameRoom(memberID: members[3].id, name: "Design Studio"))
  #expect(room.snapshot.name == "Design Studio")
  #expect(throws: RoomTransitionError.roomFull) {
    try room.handle(.join(member(MemberID(), "Ninth Mac")))
  }
  _ = try room.handle(.join(RoomMember(id: members[2].id, name: "Renamed Mac")))
  #expect(room.snapshot.members.count == 8)
}

@Test func successorCalculationExcludesDepartedCoordinator() {
  let members = [member(memberC, "C"), member(memberA, "A"), member(memberB, "B")]
  #expect(RoomStateMachine.successor(afterRemoving: memberA, from: members) == memberB)
}

@Test func typedControlProtocolRoundTripsWithoutOptionalFieldBag() throws {
  let header = ProtocolHeader(roomID: roomID, senderID: memberB, coordinatorTerm: 5)
  let original = ControlMessage(
    header: header,
    payload: .command(
      .heartbeat(
        memberID: memberB,
        health: PlaybackHealth(missingPackets: 2),
        roundTripNanoseconds: 8_000_000,
        audioLevel: 0.42
      )))
  let decoded = try ControlCodec.decode(ControlCodec.encode(original))
  #expect(decoded == original)
  #expect(decoded.header.isCompatible)
}

@Test func incompatibleProtocolHeaderIsRecognized() {
  let header = ProtocolHeader(
    roomID: roomID,
    senderID: memberA,
    coordinatorTerm: 1,
    controlVersion: ZeroSoundProtocol.controlVersion + 1
  )
  #expect(!header.isCompatible)
}

@Test func roomDescriptorRequiresMatchingControlAndAudioProtocols() {
  let compatible = RoomDescriptor(snapshot: snapshot())
  #expect(compatible.isCompatible)

  let incompatibleAudio = RoomDescriptor(
    id: compatible.id,
    name: compatible.name,
    memberCount: compatible.memberCount,
    sourceName: compatible.sourceName,
    coordinatorID: compatible.coordinatorID,
    coordinatorTerm: compatible.coordinatorTerm,
    controlProtocolVersion: compatible.controlProtocolVersion,
    audioProtocolVersion: compatible.audioProtocolVersion + 1
  )
  #expect(!incompatibleAudio.isCompatible)
}

@Test func discoverySelectionConvergesOnHighestTermAndDeterministicTieBreak() throws {
  let smallerCoordinator = MemberID(
    try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010")))
  let largerCoordinator = MemberID(
    try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000020")))
  let old = discoveredRoom(coordinatorID: smallerCoordinator, term: 4, port: 4_004)
  let new = discoveredRoom(coordinatorID: largerCoordinator, term: 5, port: 5_005)
  #expect(RoomDiscovery.prefers(new, over: old))
  #expect(!RoomDiscovery.prefers(old, over: new))

  let equalTermLarger = discoveredRoom(
    coordinatorID: largerCoordinator,
    term: 6,
    port: 6_006
  )
  let equalTermSmaller = discoveredRoom(
    coordinatorID: smallerCoordinator,
    term: 6,
    port: 6_007
  )
  #expect(RoomDiscovery.prefers(equalTermSmaller, over: equalTermLarger))
  #expect(!RoomDiscovery.prefers(equalTermLarger, over: equalTermSmaller))

  let lowerEndpoint = discoveredRoom(
    coordinatorID: smallerCoordinator,
    term: 6,
    port: 6_001
  )
  let higherEndpoint = discoveredRoom(
    coordinatorID: smallerCoordinator,
    term: 6,
    port: 6_009
  )
  #expect(RoomDiscovery.prefers(lowerEndpoint, over: higherEndpoint))
  #expect(!RoomDiscovery.prefers(higherEndpoint, over: lowerEndpoint))
}

@Test func audioFenceRejectsOldSourceAndGeneration() {
  let room = snapshot(source: .live(memberB), generation: 9)
  let valid = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 100,
    sampleRate: 48_000,
    streamGeneration: 9,
    sourceID: memberB,
    floatSamples: [0, 0]
  )
  let staleGeneration = AudioPacket(
    sequence: 2,
    presentationNanoseconds: 100,
    sampleRate: 48_000,
    streamGeneration: 8,
    sourceID: memberB,
    floatSamples: [0, 0]
  )
  let staleSource = AudioPacket(
    sequence: 3,
    presentationNanoseconds: 100,
    sampleRate: 48_000,
    streamGeneration: 9,
    sourceID: memberA,
    floatSamples: [0, 0]
  )
  #expect(AudioPacketFence.accepts(valid, snapshot: room))
  #expect(!AudioPacketFence.accepts(staleGeneration, snapshot: room))
  #expect(!AudioPacketFence.accepts(staleSource, snapshot: room))
}

private func discoveredRoom(
  coordinatorID: MemberID,
  term: UInt64,
  port: UInt16
) -> DiscoveredRoom {
  let endpointPort = NWEndpoint.Port(rawValue: port)!
  return DiscoveredRoom(
    descriptor: RoomDescriptor(
      id: roomID,
      name: "Office Room",
      memberCount: 2,
      sourceName: nil,
      coordinatorID: coordinatorID,
      coordinatorTerm: term,
      controlProtocolVersion: ZeroSoundProtocol.controlVersion,
      audioProtocolVersion: ZeroSoundProtocol.audioVersion
    ),
    endpoint: .hostPort(host: "127.0.0.1", port: endpointPort),
    audioPort: endpointPort
  )
}

@Test func diagnosticsPolicyMeasuresConsequencesInsteadOfRawNetworkImperfections() {
  let policy = RoomDiagnosticsPolicy()
  #expect(policy.evaluate(snapshot: snapshot()).severity == .excellent)

  let handledLoss = RoomMember(
    id: memberA, name: "A", connection: .ready,
    playbackHealth: PlaybackHealth(
      missingPackets: 500,
      reorderedPackets: 40,
      bufferDepthMilliseconds: 260,
      phaseErrorMilliseconds: 0,
      recentConcealedAudioMilliseconds: 95,
      recentMissingPackets: 50,
      recentReorderedPackets: 4
    ))
  #expect(
    policy.evaluate(snapshot: snapshot(members: [handledLoss], source: .live(memberA))).severity
      == .excellent
  )

  let audibleConcealment = RoomMember(
    id: memberA, name: "A", connection: .ready,
    playbackHealth: PlaybackHealth(
      missingPackets: 500,
      bufferDepthMilliseconds: 260,
      phaseErrorMilliseconds: 0,
      recentConcealedAudioMilliseconds: 100,
      recentMissingPackets: 50
    ))
  #expect(
    policy.evaluate(snapshot: snapshot(members: [audibleConcealment], source: .live(memberA)))
      .severity == .degraded
  )

  let recovering = RoomMember(
    id: memberA, name: "A", connection: .ready,
    playbackHealth: PlaybackHealth(
      rendererUnderruns: 1,
      resynchronizations: 1,
      bufferDepthMilliseconds: 260,
      phaseErrorMilliseconds: 0,
      recentRendererUnderruns: 1,
      recentResynchronizations: 1
    ))
  #expect(
    policy.evaluate(snapshot: snapshot(members: [recovering], source: .live(memberA))).severity
      == .stabilizing
  )

  let broken = RoomMember(
    id: memberA, name: "A", connection: .ready,
    playbackHealth: PlaybackHealth(
      rendererUnderruns: 4,
      resynchronizations: 1,
      recentRendererUnderruns: 4,
      recentResynchronizations: 1
    ))
  #expect(
    policy.evaluate(snapshot: snapshot(members: [broken], source: .live(memberA))).severity
      == .degraded
  )
}

@Test func diagnosticsPolicyNeverCallsUnmeasuredLivePlaybackExcellent() {
  let policy = RoomDiagnosticsPolicy()
  let unmeasured = RoomMember(
    id: memberA,
    name: "A",
    connection: .ready,
    playbackHealth: PlaybackHealth(bufferDepthMilliseconds: 260)
  )
  #expect(
    policy.evaluate(snapshot: snapshot(members: [unmeasured], source: .live(memberA))).severity
      == .stabilizing
  )

  let synchronized = RoomMember(
    id: memberA,
    name: "A",
    connection: .ready,
    playbackHealth: PlaybackHealth(
      bufferDepthMilliseconds: 260,
      phaseErrorMilliseconds: 0
    )
  )
  #expect(
    policy.evaluate(snapshot: snapshot(members: [synchronized], source: .live(memberA))).severity
      == .excellent
  )
}

@Test func diagnosticsPolicyIgnoresPreviousStreamTelemetryWhileRoomIsIdle() {
  let stale = RoomMember(
    id: memberA,
    name: "A",
    connection: .ready,
    playbackHealth: PlaybackHealth(
      missingPackets: 371,
      rendererUnderruns: 4,
      resynchronizations: 3,
      recentMissingPackets: 29,
      recentRendererUnderruns: 1
    )
  )

  let assessment = RoomDiagnosticsPolicy().evaluate(snapshot: snapshot(members: [stale]))
  #expect(assessment == .excellent)
}

@Test func diagnosticsPolicyReservesActionNeededForExplicitBlockingFailures() {
  let assessment = RoomDiagnosticsPolicy().evaluate(
    snapshot: snapshot(),
    actionRequired: "Allow system audio recording in System Settings."
  )

  #expect(assessment.severity == .actionRequired)
  #expect(assessment.summary == "Allow system audio recording in System Settings.")
}

@Test func diagnosticsPolicyTreatsAutomaticAudioPathReplacementAsStabilizing() {
  let assessment = RoomDiagnosticsPolicy().evaluate(
    snapshot: snapshot(),
    transport: TransportDiagnostics(
      control: .ready,
      audio: .degraded,
      joinStage: "Replacing audio path"
    )
  )

  #expect(assessment.severity == .stabilizing)
  #expect(assessment.cause == .restoringTransport)
}

@Test func roomHealthStabilizerPreventsRapidRecoveryOscillation() {
  var stabilizer = RoomHealthStabilizer(recoveryObservations: 3)
  let degraded = RoomHealthAssessment(severity: .degraded, cause: .playbackInterrupted)
  let recovering = RoomHealthAssessment(severity: .stabilizing, cause: .automaticRecovery)
  let stable = RoomHealthAssessment(severity: .excellent, cause: .playbackStable)

  #expect(stabilizer.observe(degraded).severity == .degraded)
  #expect(stabilizer.observe(recovering).severity == .stabilizing)
  #expect(stabilizer.observe(stable).severity == .stabilizing)
  #expect(stabilizer.observe(stable).severity == .stabilizing)
  #expect(stabilizer.observe(stable).severity == .excellent)
}

@Test func inProcessRoomIntegrationSurvivesFaultsTransferReconnectAndElection() throws {
  var network = InProcessRoomTransport(
    snapshot: snapshot(),
    clock: FixedRoomClock(now: 1_000_000_000)
  )

  network.nextControlDelivery = .duplicate
  try network.send(.join(member(memberB, "B")))
  try network.send(.join(member(memberC, "C")))
  #expect(network.reducer.snapshot.members.count == 3)

  try network.send(.requestSource(memberA))
  try network.send(.sourcePrimed(memberID: memberA, generation: 1))
  try network.send(.sourceLive(memberID: memberA, generation: 1))
  let oldPacket = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 1_300_000_000,
    sampleRate: 48_000,
    streamGeneration: 1,
    sourceID: memberA,
    floatSamples: [0.1, 0.1]
  )
  network.nextAudioDelivery = .hold
  let acceptedOldPacket = network.sendAudio(oldPacket)
  #expect(acceptedOldPacket)

  network.nextControlDelivery = .drop
  try network.send(.requestSource(memberB))
  try network.send(.sourcePrimed(memberID: memberB, generation: 2))
  try network.send(.sourceLive(memberID: memberB, generation: 2))
  network.flushHeldInReverseOrder()
  #expect(network.deliveredAudio.isEmpty)

  let newPacket = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 1_300_000_000,
    sampleRate: 48_000,
    streamGeneration: 2,
    sourceID: memberB,
    floatSamples: [0.2, 0.2]
  )
  let acceptedNewPacket = network.sendAudio(newPacket)
  #expect(acceptedNewPacket)
  #expect(network.deliveredAudio == [newPacket])

  try network.send(.join(member(memberB, "B reconnected")))
  #expect(network.reducer.snapshot.members.count == 3)
  #expect(
    network.reducer.snapshot.members.first(where: { $0.id == memberB })?.name
      == "B reconnected")

  try network.send(.leave(memberA))
  #expect(network.reducer.snapshot.coordinatorID == memberB)
  #expect(network.reducer.snapshot.coordinatorTerm == 2)
  #expect(network.reducer.snapshot.id == roomID)
  #expect(network.reducer.snapshot.audioSource == .idle)
}
