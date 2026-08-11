import Foundation
@preconcurrency import Network

public struct DiscoveredRoom: Identifiable, Hashable, @unchecked Sendable {
  public let descriptor: RoomDescriptor
  fileprivate let endpoint: NWEndpoint

  public var id: RoomID { descriptor.id }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.descriptor == rhs.descriptor && lhs.endpoint == rhs.endpoint
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(descriptor)
    hasher.combine(endpoint)
  }
}

private enum RoomAdvertisement {
  static func service(for snapshot: RoomSnapshot) -> NWListener.Service {
    let descriptor = RoomDescriptor(snapshot: snapshot)
    let record = NWTXTRecord([
      "rid": descriptor.id.rawValue.uuidString,
      "name": descriptor.name,
      "count": String(descriptor.memberCount),
      "source": descriptor.sourceName ?? "",
      "cid": descriptor.coordinatorID.rawValue.uuidString,
      "term": String(descriptor.coordinatorTerm),
      "cv": String(descriptor.controlProtocolVersion),
      "av": String(ZeroSoundProtocol.audioVersion),
    ])
    return NWListener.Service(
      name: String(descriptor.name.prefix(42)),
      type: ZeroSoundProtocol.serviceType,
      txtRecord: record
    )
  }

  static func descriptor(from record: NWTXTRecord) -> RoomDescriptor? {
    let values = record.dictionary
    guard
      let roomText = values["rid"], let roomUUID = UUID(uuidString: roomText),
      let coordinatorText = values["cid"], let coordinatorUUID = UUID(uuidString: coordinatorText),
      let countText = values["count"], let count = Int(countText),
      let termText = values["term"], let term = UInt64(termText),
      let versionText = values["cv"], let version = UInt16(versionText),
      let name = values["name"]
    else { return nil }
    let source = values["source"].flatMap { $0.isEmpty ? nil : $0 }
    let audioVersion = values["av"].flatMap(UInt8.init) ?? 0
    return RoomDescriptor(
      id: RoomID(roomUUID),
      name: name,
      memberCount: max(1, count),
      sourceName: source,
      coordinatorID: MemberID(coordinatorUUID),
      coordinatorTerm: term,
      controlProtocolVersion: version,
      audioProtocolVersion: audioVersion
    )
  }
}

final class RoomDiscovery: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.zerosound.room-discovery")
  private var browser: NWBrowser?

  var onRoomsChanged: (@Sendable ([DiscoveredRoom]) -> Void)?
  var onError: (@Sendable (String) -> Void)?

  func start() {
    guard browser == nil else { return }
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: ZeroSoundProtocol.serviceType, domain: nil),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        self?.onError?("Room discovery failed: \(error.localizedDescription)")
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      var rooms: [RoomID: DiscoveredRoom] = [:]
      for result in results {
        guard case .bonjour(let record) = result.metadata,
          let descriptor = RoomAdvertisement.descriptor(from: record)
        else { continue }
        let room = DiscoveredRoom(descriptor: descriptor, endpoint: result.endpoint)
        if let existing = rooms[room.id],
          existing.descriptor.coordinatorTerm > descriptor.coordinatorTerm
        {
          continue
        }
        rooms[room.id] = room
      }
      self?.onRoomsChanged?(
        rooms.values.sorted {
          $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        })
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
    onRoomsChanged?([])
  }
}

/// Owns the authoritative reducer and UDP fan-out while this member is coordinator.
final class RoomCoordinator: @unchecked Sendable {
  private struct Peer {
    let memberID: MemberID
    let connection: NWConnection
    var lastSeen: UInt64
  }

  private let queue = DispatchQueue(label: "com.zerosound.room-coordinator")
  private let localMemberID: MemberID
  private let advertisesRoom: Bool
  private var reducer: RoomStateMachine
  private var listener: NWListener?
  private var peers: [MemberID: Peer] = [:]
  private var unidentified: [ObjectIdentifier: NWConnection] = [:]
  private var cleanupTimer: DispatchSourceTimer?
  private var telemetryTimer: DispatchSourceTimer?
  private var routedSampleRate: UInt32?
  private var routedGeneration: UInt64?

  var onSnapshot: (@Sendable (RoomSnapshot) -> Void)?
  var onEvent: (@Sendable (RoomEvent) -> Void)?
  var onAudio: (@Sendable (AudioPacket) -> Void)?
  var onStreamFormat: (@Sendable (UInt32) -> Void)?
  var onReady: (@Sendable (DiscoveredRoom) -> Void)?
  var onError: (@Sendable (String) -> Void)?

  init(snapshot: RoomSnapshot, localMemberID: MemberID, advertisesRoom: Bool = true) {
    reducer = RoomStateMachine(snapshot: snapshot)
    self.localMemberID = localMemberID
    self.advertisesRoom = advertisesRoom
  }

  var snapshot: RoomSnapshot { queue.sync { reducer.snapshot } }

  func start() throws {
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    let listener = try NWListener(using: parameters)
    if advertisesRoom { listener.service = RoomAdvertisement.service(for: reducer.snapshot) }
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        guard let self, let port = listener.port else { return }
        let room = DiscoveredRoom(
          descriptor: RoomDescriptor(snapshot: self.reducer.snapshot),
          endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
        self.onReady?(room)
      } else if case .failed(let error) = state {
        self?.onError?("Room hosting failed: \(error.localizedDescription)")
      }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    self.listener = listener
    startCleanupTimer()
  }

  func stop() {
    queue.async { [self] in
      cleanupTimer?.cancel()
      cleanupTimer = nil
      telemetryTimer?.cancel()
      telemetryTimer = nil
      listener?.cancel()
      listener = nil
      for peer in peers.values { peer.connection.cancel() }
      peers.removeAll()
      for connection in unidentified.values { connection.cancel() }
      unidentified.removeAll()
    }
  }

  func submitLocal(_ command: RoomCommand) {
    queue.async { [self] in process(command, from: localMemberID, on: nil) }
  }

  func broadcastAudio(_ packet: AudioPacket) {
    queue.async { [self] in routeAudio(packet, from: packet.sourceID) }
  }

  private func accept(_ connection: NWConnection) {
    guard unidentified.count < 16 else {
      connection.cancel()
      return
    }
    let key = ObjectIdentifier(connection)
    unidentified[key] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      if case .failed = state { self.remove(connection) }
      if case .cancelled = state { self.remove(connection) }
    }
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else { return }
      if let data, !data.isEmpty {
        if let packet = AudioPacket.decode(data) {
          self.routeAudio(packet, from: packet.sourceID)
        } else if let message = try? ControlCodec.decode(data) {
          self.handle(message, on: connection)
        }
      }
      if error == nil { self.receive(on: connection) } else { self.remove(connection) }
    }
  }

  private func handle(_ message: ControlMessage, on connection: NWConnection) {
    guard message.header.roomID == reducer.snapshot.id else { return }
    guard reducer.snapshot.coordinatorID == localMemberID else { return }
    if !message.header.isCompatible {
      send(
        eventMessage(
          .memberRejected(
            memberID: message.header.senderID,
            reason: "Install ZeroSound \(ZeroSoundProtocol.appVersion) on every Mac in this room."
          )),
        on: connection
      )
      return
    }
    let sender = message.header.senderID
    guard message.header.coordinatorTerm == reducer.snapshot.coordinatorTerm else { return }
    identify(connection, as: sender)
    switch message.payload {
    case .command(let command): process(command, from: sender, on: connection)
    case .clockPing(let sequence, let clientSend):
      let received = MonotonicTime.nowNanoseconds()
      send(
        ControlMessage(
          header: header,
          payload: .clockPong(
            sequence: sequence,
            clientSendNanoseconds: clientSend,
            coordinatorReceiveNanoseconds: received,
            coordinatorSendNanoseconds: MonotonicTime.nowNanoseconds()
          )
        ),
        on: connection
      )
    case .event, .clockPong: break
    }
  }

  private func process(
    _ command: RoomCommand,
    from sender: MemberID,
    on connection: NWConnection?
  ) {
    guard command.isAuthorized(for: sender) else { return }
    if let connection, !reducer.snapshot.contains(sender) {
      guard case .join = command else {
        connection.cancel()
        return
      }
    }
    do {
      let events = try reducer.handle(command, nowNanoseconds: MonotonicTime.nowNanoseconds())
      let departingConnection: NWConnection?
      if case .leave(let memberID) = command {
        departingConnection = peers.removeValue(forKey: memberID)?.connection
      } else {
        departingConnection = nil
      }
      let isTelemetry: Bool
      if case .heartbeat = command { isTelemetry = true } else { isTelemetry = false }
      if !isTelemetry {
        if reducer.snapshot.coordinatorID == localMemberID {
          refreshAdvertisement()
        } else {
          listener?.service = nil
        }
      }
      for event in events {
        if isTelemetry, case .snapshot = event { continue }
        if case .memberAccepted = event, let connection {
          send(eventMessage(event), on: connection)
        } else {
          broadcast(eventMessage(event))
        }
        onEvent?(event)
      }
      if isTelemetry { scheduleTelemetrySnapshot() } else { onSnapshot?(reducer.snapshot) }
      departingConnection?.cancel()
    } catch {
      let event = RoomEvent.error(error.localizedDescription)
      if let connection {
        send(eventMessage(event), on: connection)
      } else {
        onError?(error.localizedDescription)
      }
    }
  }

  private func routeAudio(_ packet: AudioPacket, from sender: MemberID) {
    guard sender == packet.sourceID,
      AudioPacketFence.accepts(packet, snapshot: reducer.snapshot)
    else { return }
    let encoded = packet.encode()
    if routedGeneration != packet.streamGeneration || routedSampleRate != packet.sampleRate {
      routedGeneration = packet.streamGeneration
      routedSampleRate = packet.sampleRate
      onStreamFormat?(packet.sampleRate)
    }
    for peer in peers.values { send(encoded, on: peer.connection) }
    onAudio?(packet)
  }

  private func identify(_ connection: NWConnection, as memberID: MemberID) {
    let key = ObjectIdentifier(connection)
    unidentified.removeValue(forKey: key)
    if let old = peers[memberID], old.connection !== connection { old.connection.cancel() }
    if peers[memberID] == nil, peers.count >= 12 {
      connection.cancel()
      return
    }
    peers[memberID] = Peer(
      memberID: memberID,
      connection: connection,
      lastSeen: MonotonicTime.nowNanoseconds()
    )
  }

  private func remove(_ connection: NWConnection) {
    queue.async { [self] in
      unidentified.removeValue(forKey: ObjectIdentifier(connection))
      if let entry = peers.first(where: { $0.value.connection === connection }) {
        peers.removeValue(forKey: entry.key)
      }
    }
  }

  private func startCleanupTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let now = MonotonicTime.nowNanoseconds()
      let stale = self.peers.filter { now &- $0.value.lastSeen > 4_000_000_000 }
      for (id, peer) in stale {
        peer.connection.cancel()
        self.peers.removeValue(forKey: id)
        self.process(.leave(id), from: id, on: nil)
      }
    }
    timer.resume()
    cleanupTimer = timer
  }

  private var header: ProtocolHeader {
    ProtocolHeader(
      roomID: reducer.snapshot.id,
      senderID: localMemberID,
      coordinatorTerm: reducer.snapshot.coordinatorTerm
    )
  }

  private func eventMessage(_ event: RoomEvent) -> ControlMessage {
    ControlMessage(header: header, payload: .event(event))
  }

  private func refreshAdvertisement() {
    guard advertisesRoom else { return }
    listener?.service = RoomAdvertisement.service(for: reducer.snapshot)
  }

  private func scheduleTelemetrySnapshot() {
    guard telemetryTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.telemetryTimer?.cancel()
      self.telemetryTimer = nil
      let event = RoomEvent.snapshot(self.reducer.snapshot)
      self.broadcast(self.eventMessage(event))
      self.onEvent?(event)
      self.onSnapshot?(self.reducer.snapshot)
    }
    timer.resume()
    telemetryTimer = timer
  }

  private func broadcast(_ message: ControlMessage) {
    guard let data = try? ControlCodec.encode(message) else { return }
    for peer in peers.values { send(data, on: peer.connection) }
  }

  private func send(_ message: ControlMessage, on connection: NWConnection) {
    guard let data = try? ControlCodec.encode(message) else { return }
    send(data, on: connection)
  }

  private func send(_ data: Data, on connection: NWConnection) {
    connection.send(content: data, completion: .contentProcessed { _ in })
  }
}

final class RoomConnection: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.zerosound.room-connection")
  private let localMember: RoomMember
  private var connection: NWConnection?
  private var room: RoomDescriptor?
  private var estimator = ClockEstimator()
  private var pingTimer: DispatchSourceTimer?
  private var sequence: UInt64 = 0
  private var currentTerm: UInt64 = 0
  private var currentGeneration: UInt64 = 0
  private var currentSourceID: MemberID?
  private var currentSampleRate: UInt32?
  private var didDisconnect = false
  private var playbackHealth = PlaybackHealth()
  private var audioLevel: Float = 0

  var onSnapshot: (@Sendable (RoomSnapshot) -> Void)?
  var onEvent: (@Sendable (RoomEvent) -> Void)?
  var onAudio: (@Sendable (AudioPacket, UInt64) -> Void)?
  var onStreamFormat: (@Sendable (UInt32) -> Void)?
  var onClock: (@Sendable (Int64, UInt64, Int, Double) -> Void)?
  var onDisconnected: (@Sendable (String) -> Void)?
  var onError: (@Sendable (String) -> Void)?

  init(localMember: RoomMember) { self.localMember = localMember }

  func connect(to discoveredRoom: DiscoveredRoom) {
    queue.async { [self] in
      connectOnQueue(to: discoveredRoom)
    }
  }

  private func connectOnQueue(to discoveredRoom: DiscoveredRoom) {
    stopPinging()
    connection?.cancel()
    connection = nil
    estimator = ClockEstimator()
    room = discoveredRoom.descriptor
    currentTerm = discoveredRoom.descriptor.coordinatorTerm
    didDisconnect = false
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    let connection = NWConnection(to: discoveredRoom.endpoint, using: parameters)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .ready:
        self.send(.join(self.localMember), on: connection)
        self.startPinging(on: connection)
      case .failed(let error): self.reportDisconnect(error.localizedDescription)
      case .waiting(let error): self.onError?("Connection waiting: \(error.localizedDescription)")
      case .cancelled: self.stopPinging()
      default: break
      }
    }
    connection.start(queue: queue)
    self.connection = connection
    receive(on: connection)
  }

  func disconnect(notify: Bool = false) {
    queue.async { [self] in
      didDisconnect = true
      stopPinging()
      if notify, let connection, let room {
        let message = ControlMessage(
          header: ProtocolHeader(
            roomID: room.id,
            senderID: localMember.id,
            coordinatorTerm: currentTerm
          ),
          payload: .command(.leave(localMember.id))
        )
        if let data = try? ControlCodec.encode(message) {
          connection.send(
            content: data,
            completion: .contentProcessed { _ in
              connection.cancel()
            })
        } else {
          connection.cancel()
        }
      } else {
        connection?.cancel()
      }
      connection = nil
      room = nil
      estimator = ClockEstimator()
    }
  }

  func send(_ command: RoomCommand) {
    queue.async { [self] in
      guard let connection else { return }
      send(command, on: connection)
    }
  }

  func sendAudio(_ packet: AudioPacket) {
    let data = packet.encode()
    queue.async { [weak self] in
      self?.connection?.send(content: data, completion: .contentProcessed { _ in })
    }
  }

  func updateTelemetry(health: PlaybackHealth, audioLevel: Float) {
    queue.async {
      self.playbackHealth = health
      self.audioLevel = audioLevel
    }
  }

  func coordinatorTime(forLocalTime time: UInt64) -> UInt64? {
    queue.sync { estimator.coordinatorTime(forLocalTime: time) }
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else { return }
      if let data, !data.isEmpty {
        if let packet = AudioPacket.decode(data) {
          self.handle(packet)
        } else if let message = try? ControlCodec.decode(data) {
          self.handle(message)
        }
      }
      if let error {
        self.reportDisconnect(error.localizedDescription)
      } else {
        self.receive(on: connection)
      }
    }
  }

  private func handle(_ packet: AudioPacket) {
    guard packet.streamGeneration == currentGeneration,
      packet.sourceID == currentSourceID,
      let localTime = estimator.localTime(forCoordinatorTime: packet.presentationNanoseconds)
    else { return }
    if currentSampleRate != packet.sampleRate {
      currentSampleRate = packet.sampleRate
      onStreamFormat?(packet.sampleRate)
    }
    onAudio?(packet, localTime)
  }

  private func handle(_ message: ControlMessage) {
    guard let room, message.header.roomID == room.id,
      message.header.coordinatorTerm >= currentTerm
    else { return }
    currentTerm = message.header.coordinatorTerm
    switch message.payload {
    case .event(let event):
      switch event {
      case .memberRejected(_, let reason): onError?(reason)
      case .memberAccepted(let snapshot), .snapshot(let snapshot):
        if currentGeneration != snapshot.streamGeneration { currentSampleRate = nil }
        currentGeneration = snapshot.streamGeneration
        currentSourceID = snapshot.audioSource.memberID
        onSnapshot?(snapshot)
      case .streamStop(let generation, _): currentGeneration = generation
      default: break
      }
      onEvent?(event)
    case .clockPong(
      _, let clientSend, let coordinatorReceive, let coordinatorSend):
      let received = MonotonicTime.nowNanoseconds()
      estimator.add(
        ClockSample(
          clientSend: clientSend,
          coordinatorReceive: coordinatorReceive,
          coordinatorSend: coordinatorSend,
          clientReceive: received
        ))
      if let offset = estimator.coordinatorOffsetNanoseconds,
        let roundTrip = estimator.bestRoundTripNanoseconds
      {
        onClock?(
          offset,
          roundTrip,
          estimator.sampleCount,
          estimator.clockRatePartsPerMillion
        )
        send(
          .heartbeat(
            memberID: localMember.id,
            health: playbackHealth,
            roundTripNanoseconds: roundTrip,
            audioLevel: audioLevel
          ))
      }
    case .command, .clockPing: break
    }
  }

  private func startPinging(on connection: NWConnection) {
    stopPinging()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(500))
    timer.setEventHandler { [weak self, weak connection] in
      guard let self, let connection, let room = self.room else { return }
      self.sequence &+= 1
      let message = ControlMessage(
        header: ProtocolHeader(
          roomID: room.id,
          senderID: self.localMember.id,
          coordinatorTerm: self.currentTerm
        ),
        payload: .clockPing(
          sequence: self.sequence,
          clientSendNanoseconds: MonotonicTime.nowNanoseconds()
        )
      )
      self.send(message, on: connection)
    }
    timer.resume()
    pingTimer = timer
  }

  private func stopPinging() {
    pingTimer?.cancel()
    pingTimer = nil
  }

  private func send(_ command: RoomCommand, on connection: NWConnection? = nil) {
    guard let room, let target = connection ?? self.connection else { return }
    let message = ControlMessage(
      header: ProtocolHeader(
        roomID: room.id,
        senderID: localMember.id,
        coordinatorTerm: currentTerm
      ),
      payload: .command(command)
    )
    send(message, on: target)
  }

  private func send(_ message: ControlMessage, on connection: NWConnection) {
    guard let data = try? ControlCodec.encode(message) else { return }
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  private func reportDisconnect(_ detail: String) {
    guard !didDisconnect else { return }
    didDisconnect = true
    stopPinging()
    onDisconnected?("Connection interrupted: \(detail)")
  }
}

extension RoomCommand {
  fileprivate func isAuthorized(for sender: MemberID) -> Bool {
    switch self {
    case .join(let member): member.id == sender
    case .renameRoom(let memberID, _): memberID == sender
    case .leave(let memberID), .requestSource(let memberID), .releaseSource(let memberID):
      memberID == sender
    case .heartbeat(let memberID, _, _, _), .sourcePrimed(let memberID, _),
      .sourceLive(let memberID, _), .sourceStopped(let memberID, _),
      .sourceFailed(let memberID, _, _), .claimCoordinator(let memberID, _):
      memberID == sender
    }
  }
}
