import Foundation
@preconcurrency import Network

final class RoomConnection: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.zerosound.room-connection")
  private let localMember: RoomMember
  private var controlChannel: ControlChannel?
  private var audioPeer: UDPAudioPeer?
  private var discoveredRoom: DiscoveredRoom?
  private var room: RoomDescriptor?
  private var estimator = ClockEstimator()
  private var joinTimer: DispatchSourceTimer?
  private var heartbeatTimer: DispatchSourceTimer?
  private var currentTerm: UInt64 = 0
  private var currentCoordinatorID: MemberID?
  private var currentGeneration: UInt64 = 0
  private var currentSourceID: MemberID?
  private var currentSampleRate: UInt32?
  private var didDisconnect = false
  private var joinState = JoinStateMachine()
  private var playbackHealth = PlaybackHealth()
  private var audioLevel: Float = 0
  private var bestRoundTripNanoseconds: UInt64?
  private var transportDiagnostics = TransportDiagnostics.idle

  var onSnapshot: (@Sendable (RoomSnapshot) -> Void)?
  var onEvent: (@Sendable (RoomEvent) -> Void)?
  var onAudio: (@Sendable (AudioPacket, RoomClockMapping) -> Void)?
  var onStreamFormat: (@Sendable (UInt32) -> Void)?
  var onClock: (@Sendable (Int64, UInt64, Int, Double) -> Void)?
  var onDisconnected: (@Sendable (String) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  var onTransportDiagnostics: (@Sendable (TransportDiagnostics) -> Void)?

  init(localMember: RoomMember) {
    self.localMember = localMember
  }

  func connect(to discoveredRoom: DiscoveredRoom) {
    queue.async { [self] in connectOnQueue(to: discoveredRoom) }
  }

  private func connectOnQueue(to discoveredRoom: DiscoveredRoom) {
    stopConnections()
    estimator = ClockEstimator()
    self.discoveredRoom = discoveredRoom
    room = discoveredRoom.descriptor
    currentTerm = discoveredRoom.descriptor.coordinatorTerm
    currentCoordinatorID = discoveredRoom.descriptor.coordinatorID
    currentGeneration = 0
    currentSourceID = nil
    currentSampleRate = nil
    bestRoundTripNanoseconds = nil
    didDisconnect = false
    joinState = JoinStateMachine()
    do {
      try joinState.apply(.begin)
      publishTransport(control: .connecting, audio: .inactive)
    } catch {
      failJoin(error.localizedDescription)
      return
    }

    let connection = NWConnection(to: discoveredRoom.endpoint, using: tcpParameters())
    let channel = ControlChannel(connection: connection, queue: queue)
    channel.onReady = { [weak self, weak channel] in
      guard let self, let channel else { return }
      do {
        try self.joinState.apply(.controlReady)
        self.publishTransport(control: .ready, audio: .inactive)
      } catch {
        self.failJoin(error.localizedDescription)
        return
      }
      self.send(.join(self.localMember), on: channel)
    }
    channel.onMessage = { [weak self] message in self?.handle(message) }
    channel.onClose = { [weak self] reason in self?.reportDisconnect(reason) }
    controlChannel = channel
    channel.start()
    startJoinDeadline()
  }

  func disconnect(notify: Bool = false) {
    queue.async { [self] in
      didDisconnect = true
      stopTimers()
      audioPeer?.stop()
      audioPeer = nil
      if notify, let channel = controlChannel, let room {
        let message = ControlMessage(
          header: ProtocolHeader(
            roomID: room.id,
            senderID: localMember.id,
            coordinatorTerm: currentTerm
          ),
          payload: .command(.leave(localMember.id))
        )
        channel.send(message) { channel.cancel() }
      } else {
        controlChannel?.cancel()
      }
      controlChannel = nil
      self.room = nil
      discoveredRoom = nil
      currentCoordinatorID = nil
      estimator = ClockEstimator()
      try? joinState.apply(.close)
      publishTransport(control: .closed, audio: .closed)
    }
  }

  func send(_ command: RoomCommand) {
    queue.async { [self] in
      guard let controlChannel else { return }
      send(command, on: controlChannel)
    }
  }

  func sendAudio(_ packet: AudioPacket) {
    queue.async { [weak self] in self?.audioPeer?.sendAudio(packet) }
  }

  func refreshAudioPath() {
    queue.async { [weak self] in self?.requestAudioPathReplacement() }
  }

  func updateTelemetry(health: PlaybackHealth, audioLevel: Float) {
    queue.async {
      self.playbackHealth = health
      self.audioLevel = audioLevel
    }
  }

  func coordinatorTime(forLocalTime time: UInt64) -> UInt64? {
    queue.sync { estimator.mapping?.roomTime(forLocalTime: time) }
  }

  private func handle(_ message: ControlMessage) {
    guard let room, message.header.roomID == room.id,
      message.header.senderID == currentCoordinatorID,
      message.header.coordinatorTerm >= currentTerm
    else { return }
    currentTerm = message.header.coordinatorTerm

    switch message.payload {
    case .audioOffer(let portValue, let registrationToken):
      guard
        let port = NWEndpoint.Port(rawValue: portValue),
        let endpoint = audioEndpoint(port: port)
      else { return }
      if !joinState.isJoined {
        do {
          try joinState.apply(.audioOffered)
        } catch {
          failJoin(error.localizedDescription)
          return
        }
      }
      publishTransport(control: .ready, audio: .registering)
      audioPeer?.stop()
      let peer = UDPAudioPeer(
        endpoint: endpoint,
        registration: AudioPlaneRegistration(
          roomID: room.id,
          memberID: localMember.id,
          coordinatorTerm: currentTerm,
          token: registrationToken
        ),
        queue: queue
      )
      peer.onAudio = { [weak self] packet in self?.handle(packet) }
      peer.onClockSample = { [weak self] sample in self?.handle(sample) }
      peer.onError = { [weak self] message in
        self?.handleAudioPathFailure(message)
      }
      peer.onSendDrops = { [weak self] count in
        guard let self else { return }
        self.publishTransport(
          control: self.transportDiagnostics.control,
          audio: self.transportDiagnostics.audio,
          audioDatagramsDroppedBeforeSend: count
        )
      }
      audioPeer = peer
      peer.start()

    case .audioPathReady:
      guard joinState.isJoined else { return }
      audioPeer?.markRegistered()
      publishTransport(control: .ready, audio: .ready)

    case .event(let event):
      switch event {
      case .memberRejected(_, let reason):
        failJoin(reason)
        return
      case .memberAccepted(let snapshot):
        completeJoin()
        accept(snapshot)
      case .snapshot(let snapshot):
        accept(snapshot)
      case .streamStop(let generation, _):
        currentGeneration = generation
      default:
        break
      }
      onEvent?(event)

    case .command, .audioPathRequest:
      break
    }
  }

  private func accept(_ snapshot: RoomSnapshot) {
    guard snapshot.id == room?.id, snapshot.coordinatorTerm == currentTerm else { return }
    if currentGeneration != snapshot.streamGeneration { currentSampleRate = nil }
    currentGeneration = snapshot.streamGeneration
    currentSourceID = snapshot.audioSource.memberID
    currentCoordinatorID = snapshot.coordinatorID
    onSnapshot?(snapshot)
  }

  private func completeJoin() {
    guard !joinState.isJoined else { return }
    do {
      try joinState.apply(.accepted)
    } catch {
      failJoin(error.localizedDescription)
      return
    }
    joinTimer?.cancel()
    joinTimer = nil
    audioPeer?.markRegistered()
    publishTransport(control: .ready, audio: .ready)
    startHeartbeat()
  }

  private func handle(_ packet: AudioPacket) {
    guard packet.streamGeneration == currentGeneration,
      packet.sourceID == currentSourceID,
      let mapping = estimator.mapping
    else { return }
    if currentSampleRate != packet.sampleRate {
      currentSampleRate = packet.sampleRate
      onStreamFormat?(packet.sampleRate)
    }
    onAudio?(packet, mapping)
  }

  private func handle(_ sample: ClockSample) {
    estimator.add(sample)
    guard
      let offset = estimator.coordinatorOffsetNanoseconds,
      let roundTrip = estimator.bestRoundTripNanoseconds
    else { return }
    bestRoundTripNanoseconds = roundTrip
    onClock?(
      offset,
      roundTrip,
      estimator.sampleCount,
      estimator.clockRatePartsPerMillion
    )
  }

  private func startJoinDeadline() {
    joinTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(5))
    timer.setEventHandler { [weak self] in
      guard let self, !self.joinState.isJoined else { return }
      self.failJoin("The room did not acknowledge this Mac within five seconds.")
    }
    timer.resume()
    joinTimer = timer
  }

  private func startHeartbeat() {
    heartbeatTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self, self.joinState.isJoined, let channel = self.controlChannel else { return }
      self.send(
        .heartbeat(
          memberID: self.localMember.id,
          health: self.playbackHealth,
          roundTripNanoseconds: self.bestRoundTripNanoseconds,
          audioLevel: self.audioLevel
        ),
        on: channel
      )
    }
    timer.resume()
    heartbeatTimer = timer
  }

  private func audioEndpoint(port: NWEndpoint.Port) -> NWEndpoint? {
    if case .hostPort(let host, _) = controlChannel?.connection.currentPath?.remoteEndpoint {
      return .hostPort(host: host, port: port)
    }
    if case .hostPort(let host, _) = discoveredRoom?.endpoint {
      return .hostPort(host: host, port: port)
    }
    return nil
  }

  private func send(_ command: RoomCommand, on channel: ControlChannel) {
    guard let room else { return }
    channel.send(
      ControlMessage(
        header: ProtocolHeader(
          roomID: room.id,
          senderID: localMember.id,
          coordinatorTerm: currentTerm
        ),
        payload: .command(command)
      ))
  }

  private func failJoin(_ reason: String) {
    guard !didDisconnect else { return }
    guard !joinState.isJoined else {
      onError?(reason)
      return
    }
    didDisconnect = true
    try? joinState.apply(.close)
    publishTransport(control: .closed, audio: .closed)
    stopConnections()
    onDisconnected?("Could not join room: \(reason)")
  }

  private func reportDisconnect(_ detail: String) {
    guard !didDisconnect else { return }
    didDisconnect = true
    try? joinState.apply(.close)
    publishTransport(control: .closed, audio: .closed)
    stopConnections()
    onDisconnected?("Connection interrupted: \(detail)")
  }

  private func handleAudioPathFailure(_ reason: String) {
    publishTransport(control: .ready, audio: .degraded)
    onError?(reason)
    if joinState.isJoined {
      requestAudioPathReplacement()
    }
  }

  private func requestAudioPathReplacement() {
    guard joinState.isJoined, transportDiagnostics.audio != .registering,
      let controlChannel, let room
    else { return }
    audioPeer?.stop()
    audioPeer = nil
    publishTransport(control: .ready, audio: .registering)
    controlChannel.send(
      ControlMessage(
        header: ProtocolHeader(
          roomID: room.id,
          senderID: localMember.id,
          coordinatorTerm: currentTerm
        ),
        payload: .audioPathRequest
      ))
  }

  private func stopConnections() {
    stopTimers()
    audioPeer?.stop()
    audioPeer = nil
    controlChannel?.cancel()
    controlChannel = nil
  }

  private func stopTimers() {
    joinTimer?.cancel()
    joinTimer = nil
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
  }

  private func publishTransport(
    control: TransportLinkState,
    audio: TransportLinkState,
    audioDatagramsDroppedBeforeSend: UInt64? = nil
  ) {
    let diagnostics = TransportDiagnostics(
      control: control,
      audio: audio,
      joinStage: joinStageDescription,
      audioDatagramsDroppedBeforeSend: audioDatagramsDroppedBeforeSend
        ?? transportDiagnostics.audioDatagramsDroppedBeforeSend
    )
    guard diagnostics != transportDiagnostics else { return }
    transportDiagnostics = diagnostics
    onTransportDiagnostics?(diagnostics)
  }

  private var joinStageDescription: String {
    switch joinState.phase {
    case .idle: "Idle"
    case .connectingControl: "Connecting control"
    case .awaitingAudioOffer: "Control ready"
    case .registeringAudio: "Registering audio"
    case .joined: "Ready"
    case .closed: "Closed"
    }
  }
}
