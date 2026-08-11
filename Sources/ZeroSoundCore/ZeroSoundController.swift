import Combine
import Foundation

@MainActor
public final class ZeroSoundController: ObservableObject {
  @Published public private(set) var membership: MembershipState = .discovering {
    didSet { refreshRoomHealth() }
  }
  @Published public private(set) var nearbyRooms: [DiscoveredRoom] = []
  @Published public private(set) var status = "Looking for nearby rooms…"
  @Published public private(set) var playbackHealth = PlaybackHealth() {
    didSet { refreshRoomHealth() }
  }
  @Published public private(set) var clockOffsetMilliseconds: Double?
  @Published public private(set) var roundTripMilliseconds: Double?
  @Published public private(set) var clockSampleCount = 0
  @Published public private(set) var clockSkewPartsPerMillion: Double?
  @Published public private(set) var streamSampleRate: Double?
  @Published public private(set) var droppedCaptureFrames: UInt64 = 0
  @Published public private(set) var streamedPacketCount: UInt64 = 0
  @Published public private(set) var capturePeakLevel: Float = 0
  @Published public private(set) var lastIncident: String?
  @Published public private(set) var transportDiagnostics = TransportDiagnostics.idle {
    didSet { refreshRoomHealth() }
  }
  @Published public private(set) var roomHealth = RoomHealthAssessment.excellent

  public let localMemberID: MemberID
  public let deviceName: String

  public var room: RoomSnapshot? {
    if case .inRoom(let snapshot) = membership { snapshot } else { nil }
  }

  public var isInRoom: Bool { room != nil }
  public var isReconnecting: Bool {
    if case .reconnecting = membership { true } else { false }
  }
  public var isLocalCoordinator: Bool { room?.coordinatorID == localMemberID }
  public var isLocalSource: Bool { room?.audioSource.memberID == localMemberID }
  public var isAudioLive: Bool { room?.audioSource.isLive == true }
  public var healthSeverity: RoomHealthSeverity { roomHealth.severity }

  private let defaults: UserDefaults
  private let discovery = RoomDiscovery()
  private let audioRenderer = SynchronizedAudioRenderer()
  private let diagnosticsPolicy = RoomDiagnosticsPolicy()
  private var healthStabilizer = RoomHealthStabilizer()
  private var actionRequiredMessage: String? {
    didSet { refreshRoomHealth() }
  }
  private var membershipMachine = MembershipStateMachine()
  private var coordinator: RoomCoordinator?
  private var connection: RoomConnection?
  private var connectedCoordinatorID: MemberID?
  private var audioStreamer: SystemAudioStreamer?
  private var reconnectTask: Task<Void, Never>?
  private var operationGeneration: UInt64 = 0
  private var processActivity: NSObjectProtocol?
  private var shouldReconnectAfterWake = false
  private var sleepingSnapshot: RoomSnapshot?
  private var preferredRoomID: RoomID?

  public init(deviceName: String? = nil, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let savedID = defaults.string(forKey: PreferenceKey.memberID).flatMap(UUID.init(uuidString:))
    let identity = MemberID(savedID ?? UUID())
    localMemberID = identity
    preferredRoomID = defaults.string(forKey: PreferenceKey.preferredRoomID)
      .flatMap(UUID.init(uuidString:)).map(RoomID.init)
    defaults.set(identity.rawValue.uuidString, forKey: PreferenceKey.memberID)
    self.deviceName = Self.cleanDeviceName(
      deviceName ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    )

    discovery.onRoomsChanged = { [weak self] rooms in
      Task { @MainActor in
        guard let self else { return }
        self.nearbyRooms = rooms.filter { $0.id != self.room?.id }.sorted {
          if $0.id == self.preferredRoomID { return true }
          if $1.id == self.preferredRoomID { return false }
          return $0.descriptor.name.localizedStandardCompare($1.descriptor.name)
            == .orderedAscending
        }
        self.considerReconnect(in: rooms)
      }
    }
    discovery.onError = { [weak self] message in
      Task { @MainActor in self?.report(message) }
    }
    audioRenderer.onStatistics = { [weak self] health in
      Task { @MainActor in
        guard let self else { return }
        self.playbackHealth = health
        self.connection?.updateTelemetry(health: health, audioLevel: self.capturePeakLevel)
      }
    }
    startDiscovery()
  }

  public func startDiscovery() {
    discovery.start()
    if case .discovering = membership {
      try? membershipMachine.discoveryReady()
      membership = membershipMachine.state
    }
    if !isInRoom { status = "Choose a nearby room or create Office Room." }
  }

  public func createRoom() {
    guard case .outsideRoom = membership else { return }
    beginDiagnosticsSession()
    operationGeneration &+= 1
    let roomID = RoomID()
    do {
      try membershipMachine.beginCreate(roomID: roomID)
      membership = membershipMachine.state
      let local = localMember(connection: .ready)
      let name = defaults.string(forKey: PreferenceKey.roomName) ?? "Office Room"
      let snapshot = RoomSnapshot(
        id: roomID,
        name: name,
        coordinatorID: localMemberID,
        members: [local]
      )
      try becomeCoordinator(with: snapshot, completingJoin: true)
      defaults.set(name, forKey: PreferenceKey.roomName)
      remember(roomID)
      beginProcessActivity()
      status = "\(name) is ready. Choose Play from this Mac when you want audio."
    } catch {
      resetToDiscovery(error: "Could not create the room: \(error.localizedDescription)")
    }
  }

  public func join(_ discoveredRoom: DiscoveredRoom) {
    guard case .outsideRoom = membership else { return }
    guard discoveredRoom.descriptor.isCompatible else {
      report("This room needs the same ZeroSound version on every Mac.")
      return
    }
    beginDiagnosticsSession()
    operationGeneration &+= 1
    do {
      try membershipMachine.beginJoin(roomID: discoveredRoom.id)
      membership = membershipMachine.state
      connect(to: discoveredRoom)
      remember(discoveredRoom.id)
      beginProcessActivity()
      status = "Joining \(discoveredRoom.descriptor.name)…"
    } catch {
      report(error.localizedDescription)
    }
  }

  public func leaveRoom() {
    guard let snapshot = room else {
      if case .reconnecting = membership { finishLeaving() }
      return
    }
    operationGeneration &+= 1
    stopCaptureAndPlayback()
    do {
      try membershipMachine.beginLeave()
      membership = membershipMachine.state
    } catch { return }

    if let coordinator {
      coordinator.submitLocal(.leave(localMemberID))
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        self?.finishLeaving()
      }
    } else {
      connection?.disconnect(notify: true)
      finishLeaving()
    }
    status = "Leaving \(snapshot.name)…"
  }

  public func playFromThisMac() {
    guard let room, room.contains(localMemberID) else { return }
    send(.requestSource(localMemberID))
  }

  public func stopAudio() {
    guard isLocalSource else { return }
    send(.releaseSource(localMemberID))
  }

  public func renameRoom(_ name: String) {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    defaults.set(String(cleaned.prefix(64)), forKey: PreferenceKey.roomName)
    if isInRoom {
      send(.renameRoom(memberID: localMemberID, name: cleaned))
    }
  }

  public func prepareForSystemSleep() {
    sleepingSnapshot = room
    shouldReconnectAfterWake = isInRoom
    stopCaptureAndPlayback()
    coordinator?.stop()
    coordinator = nil
    connection?.disconnect()
    connection = nil
    connectedCoordinatorID = nil
    if isInRoom { try? membershipMachine.connectionLost() }
    membership = membershipMachine.state
    status = "Paused while this Mac sleeps."
  }

  public func resumeAfterSystemWake() {
    guard shouldReconnectAfterWake else { return }
    shouldReconnectAfterWake = false
    status = "Finding the room again…"
    startDiscovery()
    considerReconnect(in: nearbyRooms)
    guard let sleepingSnapshot,
      sleepingSnapshot.members.count == 1,
      sleepingSnapshot.contains(localMemberID)
    else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, case .reconnecting = self.membership, self.nearbyRooms.isEmpty else { return }
      var restored = sleepingSnapshot
      restored.coordinatorID = self.localMemberID
      restored.coordinatorTerm &+= 1
      restored.streamGeneration &+= 1
      restored.audioSource = .idle
      do {
        self.operationGeneration &+= 1
        try self.becomeCoordinator(with: restored, completingJoin: true)
        self.status = "\(restored.name) is ready again."
      } catch {
        self.report("Could not restore the room after wake: \(error.localizedDescription)")
      }
    }
  }

  public func diagnosticsReport() -> String {
    var lines = [
      "ZeroSound \(ZeroSoundProtocol.appVersion)",
      "This Mac: \(deviceName) [\(localMemberID)]",
      "State: \(membershipDescription)",
      "Room health: \(healthSeverity.title)",
      "Health detail: \(roomHealth.summary)",
      "Status: \(status)",
      "Control transport: \(transportDiagnostics.control.rawValue)",
      "Audio transport: \(transportDiagnostics.audio.rawValue)",
      "Join stage: \(transportDiagnostics.joinStage)",
      "Audio dropped before send: \(transportDiagnostics.audioDatagramsDroppedBeforeSend)",
      "Clock offset: \(formatted(clockOffsetMilliseconds, suffix: "ms"))",
      "Round trip: \(formatted(roundTripMilliseconds, suffix: "ms"))",
      "Clock samples: \(clockSampleCount)",
      "Clock skew: \(formatted(clockSkewPartsPerMillion, suffix: "ppm"))",
      "Sample rate: \(streamSampleRate.map { String(format: "%.0f Hz", $0) } ?? "n/a")",
      "Packets sent: \(streamedPacketCount)",
      "Capture drops: \(droppedCaptureFrames)",
    ]
    if let room {
      lines.append("Room: \(room.name) [\(room.id)]")
      lines.append("Coordinator term: \(room.coordinatorTerm)")
      lines.append("Coordinator: \(room.coordinatorID)")
      lines.append("Stream generation: \(room.streamGeneration)")
      lines.append("Audio source: \(room.sourceMember?.name ?? "idle")")
      for member in room.members {
        let health = member.id == localMemberID ? playbackHealth : member.playbackHealth
        lines.append(
          "Member \(member.name): \(member.connection.rawValue), RTT \(formattedNanoseconds(member.roundTripNanoseconds)), worst RTT \(formattedNanoseconds(member.worstRoundTripNanoseconds)), missing \(health.missingPackets) (recent \(health.recentMissingPackets)), late \(health.latePackets) (recent \(health.recentLatePackets)), concealed \(String(format: "%.1f ms", health.concealedAudioMilliseconds)) (recent \(String(format: "%.1f ms", health.recentConcealedAudioMilliseconds))), reordered \(health.reorderedPackets) (recent \(health.recentReorderedPackets)), underruns \(health.rendererUnderruns) (recent \(health.recentRendererUnderruns)), resyncs \(health.resynchronizations), phase \(formatted(health.phaseErrorMilliseconds, suffix: "ms")), rate \(String(format: "%.0f ppm", health.playbackRatePartsPerMillion)), queue \(String(format: "%.1f ms", health.bufferDepthMilliseconds))"
        )
      }
    }
    if let actionRequiredMessage { lines.append("Action required: \(actionRequiredMessage)") }
    if let lastIncident { lines.append("Last incident: \(lastIncident)") }
    return lines.joined(separator: "\n")
  }

  private func formattedNanoseconds(_ value: UInt64?) -> String {
    value.map { String(format: "%.1f ms", Double($0) / 1_000_000) } ?? "n/a"
  }

  private func connect(to discoveredRoom: DiscoveredRoom) {
    connection?.disconnect()
    resetClockMetrics()
    let connection = RoomConnection(localMember: localMember())
    configure(connection)
    connection.connect(to: discoveredRoom)
    self.connection = connection
    connectedCoordinatorID = discoveredRoom.descriptor.coordinatorID
  }

  private func configure(_ connection: RoomConnection) {
    let generation = operationGeneration
    connection.onSnapshot = { [weak self] snapshot in
      Task { @MainActor in
        guard let self, self.operationGeneration == generation else { return }
        self.accept(snapshot)
      }
    }
    connection.onEvent = { [weak self] event in
      Task { @MainActor in
        guard let self, self.operationGeneration == generation else { return }
        self.handle(event)
      }
    }
    connection.onAudio = { [weak self] packet, mapping in
      self?.audioRenderer.enqueue(packet, roomClockMapping: mapping)
    }
    connection.onStreamFormat = { [weak self] sampleRate in
      Task { @MainActor in self?.streamSampleRate = Double(sampleRate) }
    }
    connection.onClock = { [weak self] offset, roundTrip, samples, skew in
      Task { @MainActor in
        self?.clockOffsetMilliseconds = Double(offset) / 1_000_000
        self?.roundTripMilliseconds = Double(roundTrip) / 1_000_000
        self?.clockSampleCount = samples
        self?.clockSkewPartsPerMillion = skew
      }
    }
    connection.onDisconnected = { [weak self] reason in
      Task { @MainActor in
        guard let self, self.operationGeneration == generation else { return }
        self.handleDisconnection(reason)
      }
    }
    connection.onError = { [weak self] message in
      Task { @MainActor in self?.report(message) }
    }
    connection.onTransportDiagnostics = { [weak self] diagnostics in
      Task { @MainActor in self?.transportDiagnostics = diagnostics }
    }
  }

  private func becomeCoordinator(with snapshot: RoomSnapshot, completingJoin: Bool) throws {
    connection?.disconnect()
    connection = nil
    connectedCoordinatorID = nil
    coordinator?.stop()
    resetClockMetrics()
    let coordinator = RoomCoordinator(snapshot: snapshot, localMemberID: localMemberID)
    let generation = operationGeneration
    coordinator.onSnapshot = { [weak self] snapshot in
      Task { @MainActor in
        guard let self, self.operationGeneration == generation else { return }
        self.accept(snapshot)
      }
    }
    coordinator.onEvent = { [weak self] event in
      Task { @MainActor in
        guard let self, self.operationGeneration == generation else { return }
        self.handle(event)
      }
    }
    coordinator.onAudio = { [weak self] packet in
      self?.audioRenderer.enqueue(packet, roomClockMapping: .identity)
    }
    coordinator.onStreamFormat = { [weak self] sampleRate in
      Task { @MainActor in self?.streamSampleRate = Double(sampleRate) }
    }
    coordinator.onError = { [weak self] message in
      Task { @MainActor in
        guard let self else { return }
        self.actionRequiredMessage = message
        self.report(message)
      }
    }
    coordinator.onAudioSendDrops = { [weak self] count in
      Task { @MainActor in
        guard let self else { return }
        self.transportDiagnostics = self.transportDiagnostics
          .withAudioDatagramsDroppedBeforeSend(count)
      }
    }
    try coordinator.start()
    self.coordinator = coordinator
    transportDiagnostics = .localCoordinator
    if completingJoin {
      try membershipMachine.joined(snapshot)
      membership = membershipMachine.state
    } else {
      accept(snapshot)
    }
  }

  private func accept(_ snapshot: RoomSnapshot) {
    do {
      switch membershipMachine.state {
      case .joining, .creating, .reconnecting:
        try membershipMachine.joined(snapshot)
      case .inRoom:
        try membershipMachine.apply(snapshot)
      default: return
      }
      membership = membershipMachine.state
      if let sourceID = snapshot.audioSource.memberID, sourceID != localMemberID {
        actionRequiredMessage = nil
      }
      status =
        snapshot.audioSource.isLive
        ? "Playing system audio from \(snapshot.sourceMember?.name ?? "a room member")."
        : "\(snapshot.name) is ready."
      if snapshot.coordinatorID == localMemberID, coordinator == nil {
        try becomeCoordinator(with: snapshot, completingJoin: false)
      }
      if snapshot.audioSource == .live(localMemberID), audioStreamer == nil {
        startSource(generation: snapshot.streamGeneration, announcesPrimed: false)
      }
    } catch {
      report(error.localizedDescription)
    }
  }

  private func handle(_ event: RoomEvent) {
    switch event {
    case .sourceAssignment(let memberID, let generation) where memberID == localMemberID:
      prepareSource(generation: generation)
    case .streamStart(let memberID, let generation, _)
    where memberID == localMemberID:
      send(.sourceLive(memberID: localMemberID, generation: generation))
    case .streamStop(let generation, let acknowledgement):
      stopCaptureAndPlayback()
      if acknowledgement == localMemberID {
        send(.sourceStopped(memberID: localMemberID, generation: generation))
      }
    case .memberRejected(_, let reason), .error(let reason):
      report(reason)
    default: break
    }
  }

  private func prepareSource(generation: UInt64) {
    startSource(generation: generation, announcesPrimed: true)
  }

  private func startSource(generation: UInt64, announcesPrimed: Bool) {
    stopCaptureAndPlayback()
    actionRequiredMessage = nil
    do {
      let connection = self.connection
      let coordinator = self.coordinator
      let streamer = try SystemAudioStreamer(
        sourceID: localMemberID,
        streamGeneration: generation,
        roomTime: { localTime in
          if coordinator != nil { return localTime }
          return connection?.coordinatorTime(forLocalTime: localTime)
        }
      )
      streamer.onPacket = { packet in
        if let coordinator {
          coordinator.broadcastAudio(packet)
        } else {
          connection?.sendAudio(packet)
        }
      }
      streamer.onStatistics = { [weak self] statistics in
        Task { @MainActor in
          guard let self else { return }
          guard self.room?.streamGeneration == generation, self.isLocalSource else { return }
          self.droppedCaptureFrames = statistics.droppedFrames
          self.streamedPacketCount = statistics.packetsSent
          self.capturePeakLevel = statistics.peakLevel
          self.connection?.updateTelemetry(
            health: self.playbackHealth,
            audioLevel: statistics.peakLevel
          )
          if self.isLocalCoordinator {
            self.send(
              .heartbeat(
                memberID: self.localMemberID,
                health: self.playbackHealth,
                roundTripNanoseconds: nil,
                audioLevel: statistics.peakLevel
              ))
          }
        }
      }
      let sampleRate = try streamer.start()
      audioStreamer = streamer
      streamSampleRate = sampleRate
      if announcesPrimed {
        send(.sourcePrimed(memberID: localMemberID, generation: generation))
      }
    } catch {
      let message = "Audio capture failed: \(error.localizedDescription)"
      actionRequiredMessage = message
      send(
        .sourceFailed(
          memberID: localMemberID,
          generation: generation,
          reason: error.localizedDescription
        ))
      report(message)
    }
  }

  private func send(_ command: RoomCommand) {
    if let coordinator { coordinator.submitLocal(command) } else { connection?.send(command) }
  }

  private func handleDisconnection(_ reason: String) {
    if case .joining = membership {
      resetToDiscovery(error: reason)
      return
    }
    if case .reconnecting = membership {
      lastIncident = reason
      scheduleReconnect()
      return
    }
    guard let snapshot = room else { return }
    let departedCoordinatorID = connectedCoordinatorID ?? snapshot.coordinatorID
    stopCaptureAndPlayback()
    connection?.disconnect()
    connection = nil
    connectedCoordinatorID = nil
    try? membershipMachine.connectionLost()
    membership = membershipMachine.state
    status = "Reconnecting to \(snapshot.name)…"
    lastIncident = reason

    var survivors = snapshot.members.filter { $0.id != departedCoordinatorID }
    survivors = survivors.map {
      var member = $0
      member.connection = member.id == localMemberID ? .ready : .reconnecting
      return member
    }
    let alreadyElectedCoordinator =
      snapshot.coordinatorID != departedCoordinatorID && snapshot.contains(snapshot.coordinatorID)
      ? snapshot.coordinatorID : nil
    guard let successor = alreadyElectedCoordinator ?? RoomStateMachine.successor(in: survivors)
    else {
      resetToDiscovery(error: "The room ended because no members remained.")
      return
    }
    if successor == localMemberID {
      var promoted = snapshot
      promoted.replaceMembers(survivors)
      promoted.coordinatorID = localMemberID
      if alreadyElectedCoordinator == nil {
        promoted.coordinatorTerm &+= 1
        promoted.streamGeneration &+= 1
        promoted.audioSource = .idle
        promoted.resetStreamTelemetry()
      }
      do {
        try becomeCoordinator(with: promoted, completingJoin: true)
        status = "\(promoted.name) recovered. Audio is ready to restart."
      } catch {
        scheduleReconnect()
      }
    } else {
      scheduleReconnect()
    }
  }

  private func scheduleReconnect() {
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      self?.considerReconnect(in: self?.nearbyRooms ?? [])
    }
  }

  private func considerReconnect(in rooms: [DiscoveredRoom]) {
    guard case .reconnecting(let roomID) = membership,
      let room = rooms.first(where: { $0.id == roomID })
    else { return }
    operationGeneration &+= 1
    connect(to: room)
  }

  private func finishLeaving() {
    reconnectTask?.cancel()
    reconnectTask = nil
    coordinator?.stop()
    coordinator = nil
    connection?.disconnect()
    connection = nil
    connectedCoordinatorID = nil
    if case .leaving = membershipMachine.state {
      try? membershipMachine.left()
    } else {
      membershipMachine = MembershipStateMachine(state: .outsideRoom)
    }
    membership = membershipMachine.state
    endProcessActivity()
    clearMetrics()
    status = "Choose a nearby room or create Office Room."
  }

  private func resetToDiscovery(error: String) {
    reconnectTask?.cancel()
    reconnectTask = nil
    stopCaptureAndPlayback()
    coordinator?.stop()
    coordinator = nil
    connection?.disconnect()
    connection = nil
    connectedCoordinatorID = nil
    membershipMachine = MembershipStateMachine(state: .outsideRoom)
    membership = membershipMachine.state
    endProcessActivity()
    clearMetrics()
    report(error)
  }

  private func stopCaptureAndPlayback() {
    audioStreamer?.stop()
    audioStreamer = nil
    audioRenderer.stop()
    resetStreamMetrics()
  }

  private func clearMetrics() {
    resetStreamMetrics()
    resetClockMetrics()
    transportDiagnostics = .idle
    lastIncident = nil
    actionRequiredMessage = nil
    healthStabilizer.reset()
    roomHealth = .excellent
  }

  private func resetStreamMetrics() {
    playbackHealth = PlaybackHealth()
    streamSampleRate = nil
    droppedCaptureFrames = 0
    streamedPacketCount = 0
    capturePeakLevel = 0
  }

  private func resetClockMetrics() {
    clockOffsetMilliseconds = nil
    roundTripMilliseconds = nil
    clockSampleCount = 0
    clockSkewPartsPerMillion = nil
  }

  private func beginDiagnosticsSession() {
    clearMetrics()
  }

  private func refreshRoomHealth() {
    guard var snapshot = room else {
      let assessment =
        isReconnecting
        ? RoomHealthAssessment(severity: .stabilizing, cause: .reconnecting)
        : RoomHealthAssessment.excellent
      roomHealth = healthStabilizer.observe(assessment)
      return
    }
    if let localIndex = snapshot.members.firstIndex(where: { $0.id == localMemberID }) {
      snapshot.members[localIndex].playbackHealth = playbackHealth
    }
    let assessment = diagnosticsPolicy.evaluate(
      snapshot: snapshot,
      reconnecting: isReconnecting,
      transport: transportDiagnostics,
      actionRequired: actionRequiredMessage
    )
    roomHealth = healthStabilizer.observe(assessment)
  }

  private func report(_ message: String) {
    lastIncident = message
    status = message
  }

  private func localMember(connection: MemberConnectionState = .synchronizing) -> RoomMember {
    RoomMember(id: localMemberID, name: deviceName, connection: connection)
  }

  private func remember(_ roomID: RoomID) {
    preferredRoomID = roomID
    defaults.set(roomID.rawValue.uuidString, forKey: PreferenceKey.preferredRoomID)
  }

  private var membershipDescription: String {
    switch membership {
    case .discovering: "discovering"
    case .outsideRoom: "outside room"
    case .creating: "creating"
    case .joining: "joining"
    case .inRoom: "in room"
    case .reconnecting: "reconnecting"
    case .leaving: "leaving"
    }
  }

  private func formatted(_ value: Double?, suffix: String) -> String {
    value.map { String(format: "%.2f %@", $0, suffix) } ?? "n/a"
  }

  private static func cleanDeviceName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let clean = trimmed.hasSuffix(".local") ? String(trimmed.dropLast(6)) : trimmed
    return clean.isEmpty ? "Mac" : String(clean.prefix(64))
  }

  private func beginProcessActivity() {
    guard processActivity == nil else { return }
    processActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled],
      reason: "Keeping the ZeroSound room and synchronized audio active"
    )
  }

  private func endProcessActivity() {
    guard let processActivity else { return }
    ProcessInfo.processInfo.endActivity(processActivity)
    self.processActivity = nil
  }
}

private enum PreferenceKey {
  static let memberID = "room.memberID"
  static let roomName = "room.defaultName"
  static let preferredRoomID = "room.preferredID"
}
