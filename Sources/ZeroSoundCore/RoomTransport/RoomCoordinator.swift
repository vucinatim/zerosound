import Foundation
@preconcurrency import Network

/// Owns the authoritative room reducer and composes independent TCP control and UDP audio planes.
final class RoomCoordinator: @unchecked Sendable {
  private static let audioRegistrationLifetimeNanoseconds: UInt64 = 5_000_000_000

  private struct ControlPeer {
    let channel: ControlChannel
    var candidate: RoomMember?
    var registrationLease: AudioRegistrationLease?
    var isJoined = false
    var lastSeenNanoseconds: UInt64
  }

  private let queue = DispatchQueue(label: "com.zerosound.room-coordinator")
  private let localMemberID: MemberID
  private let advertisesRoom: Bool
  private var reducer: RoomStateMachine
  private var controlListener: NWListener?
  private var audioRouter: UDPAudioRouter!
  private var audioPort: NWEndpoint.Port?
  private var peers: [ObjectIdentifier: ControlPeer] = [:]
  private var connectionByMember: [MemberID: ObjectIdentifier] = [:]
  private var unboundMemberDeadlines: [MemberID: UInt64] = [:]
  private var cleanupTimer: DispatchSourceTimer?
  private var telemetryTimer: DispatchSourceTimer?
  private var isRunning = false

  var onSnapshot: (@Sendable (RoomSnapshot) -> Void)?
  var onEvent: (@Sendable (RoomEvent) -> Void)?
  var onAudio: (@Sendable (AudioPacket) -> Void)?
  var onStreamFormat: (@Sendable (UInt32) -> Void)?
  var onReady: (@Sendable (DiscoveredRoom) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  var onAudioSendDrops: (@Sendable (UInt64) -> Void)?

  init(snapshot: RoomSnapshot, localMemberID: MemberID, advertisesRoom: Bool = true) {
    reducer = RoomStateMachine(snapshot: snapshot)
    self.localMemberID = localMemberID
    self.advertisesRoom = advertisesRoom
    audioRouter = UDPAudioRouter()
    let reconnectDeadline = MonotonicTime.nowNanoseconds() &+ 5_000_000_000
    unboundMemberDeadlines = Dictionary(
      uniqueKeysWithValues: snapshot.members.compactMap { member in
        member.id == localMemberID ? nil : (member.id, reconnectDeadline)
      })
    configureAudioRouter()
    audioRouter.updateRoute(snapshot)
  }

  var snapshot: RoomSnapshot { queue.sync { reducer.snapshot } }

  func start() throws {
    try queue.sync {
      guard !isRunning, reducer.snapshot.coordinatorID == localMemberID else {
        throw RoomTransitionError.invalidMembershipTransition
      }
      isRunning = true
      do {
        try audioRouter.start()
        startCleanupTimer()
      } catch {
        isRunning = false
        throw error
      }
    }
  }

  func stop() {
    queue.async { [self] in
      isRunning = false
      cleanupTimer?.cancel()
      cleanupTimer = nil
      telemetryTimer?.cancel()
      telemetryTimer = nil
      controlListener?.cancel()
      controlListener = nil
      for peer in peers.values { peer.channel.cancel() }
      peers.removeAll()
      connectionByMember.removeAll()
      unboundMemberDeadlines.removeAll()
      audioRouter.stop()
      audioPort = nil
    }
  }

  func submitLocal(_ command: RoomCommand) {
    queue.async { [self] in apply(command, from: localMemberID, replyTo: nil) }
  }

  func broadcastAudio(_ packet: AudioPacket) {
    audioRouter.routeAudio(packet, from: localMemberID)
  }

  private func configureAudioRouter() {
    audioRouter.validatesRegistration = { [weak self] registration in
      guard let self else { return false }
      return self.queue.sync { self.consume(registration) }
    }
    audioRouter.onRegistered = { [weak self] memberID in
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.completeJoin(for: memberID)
      }
    }
    audioRouter.onRoutedAudio = { [weak self] packet in
      self?.onAudio?(packet)
    }
    audioRouter.onStreamFormat = { [weak self] sampleRate in
      self?.onStreamFormat?(sampleRate)
    }
    audioRouter.onPeerActivity = { [weak self] memberID in
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.markActive(memberID)
      }
    }
    audioRouter.onReady = { [weak self] port in
      guard let self else { return }
      self.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.audioPort = port
        self.startControlListener(audioPort: port)
      }
    }
    audioRouter.onError = { [weak self] message in
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.onError?(message)
      }
    }
    audioRouter.onSendDrops = { [weak self] count in
      self?.queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.onAudioSendDrops?(count)
      }
    }
  }

  private func startControlListener(audioPort: NWEndpoint.Port) {
    do {
      let listener = try NWListener(using: tcpParameters())
      if advertisesRoom {
        listener.service = RoomAdvertisement.service(
          for: reducer.snapshot,
          audioPort: audioPort
        )
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let controlPort = listener?.port else { return }
          self.onReady?(
            DiscoveredRoom(
              descriptor: RoomDescriptor(snapshot: self.reducer.snapshot),
              endpoint: .hostPort(host: "127.0.0.1", port: controlPort),
              audioPort: audioPort
            ))
        case .failed(let error):
          self.onError?("Room hosting failed: \(error.localizedDescription)")
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.acceptControl(connection)
      }
      listener.start(queue: queue)
      controlListener = listener
    } catch {
      onError?("Room hosting failed: \(error.localizedDescription)")
    }
  }

  private func acceptControl(_ connection: NWConnection) {
    guard peers.count < 16 else {
      connection.cancel()
      return
    }
    let channel = ControlChannel(connection: connection, queue: queue)
    let key = ObjectIdentifier(channel)
    peers[key] = ControlPeer(
      channel: channel,
      lastSeenNanoseconds: MonotonicTime.nowNanoseconds()
    )
    channel.onMessage = { [weak self] message in self?.handle(message, from: key) }
    channel.onClose = { [weak self] _ in self?.removePeer(key, removesMember: true) }
    channel.start()
  }

  private func handle(_ message: ControlMessage, from key: ObjectIdentifier) {
    guard var peer = peers[key] else { return }
    guard message.header.roomID == reducer.snapshot.id else { return }
    guard reducer.snapshot.coordinatorID == localMemberID else { return }
    peer.lastSeenNanoseconds = MonotonicTime.nowNanoseconds()
    peers[key] = peer

    if !message.header.isCompatible {
      peer.channel.send(
        eventMessage(
          .memberRejected(
            memberID: message.header.senderID,
            reason: "Install ZeroSound \(ZeroSoundProtocol.appVersion) on every Mac in this room."
          )))
      return
    }
    guard message.header.coordinatorTerm == reducer.snapshot.coordinatorTerm else { return }

    if !peer.isJoined {
      guard
        case .command(.join(let member)) = message.payload,
        member.id == message.header.senderID
      else { return }
      peer.candidate = member
      peers[key] = peer
      offerAudioPath(to: key, rotatesToken: false)
      return
    }

    let sender = message.header.senderID
    guard peer.candidate?.id == sender, connectionByMember[sender] == key else { return }
    switch message.payload {
    case .command(let command):
      apply(command, from: sender, replyTo: peer.channel)
    case .audioPathRequest:
      offerAudioPath(to: key, rotatesToken: true)
    case .event, .audioOffer, .audioPathReady:
      break
    }
  }

  private func consume(_ registration: AudioPlaneRegistration) -> Bool {
    guard
      isRunning,
      reducer.snapshot.coordinatorID == localMemberID,
      registration.roomID == reducer.snapshot.id,
      registration.coordinatorTerm == reducer.snapshot.coordinatorTerm,
      let entry = peers.first(where: { $0.value.candidate?.id == registration.memberID }),
      var peer = peers[entry.key],
      var lease = peer.registrationLease,
      lease.consume(
        token: registration.token,
        at: MonotonicTime.nowNanoseconds()
      )
    else { return false }
    peer.registrationLease = lease
    peers[entry.key] = peer
    return true
  }

  private func completeJoin(for memberID: MemberID) {
    guard
      isRunning,
      reducer.snapshot.coordinatorID == localMemberID,
      let entry = peers.first(where: { $0.value.candidate?.id == memberID }),
      var peer = peers[entry.key],
      let member = peer.candidate
    else { return }
    if peer.isJoined {
      peer.registrationLease = nil
      peer.lastSeenNanoseconds = MonotonicTime.nowNanoseconds()
      peers[entry.key] = peer
      peer.channel.send(
        ControlMessage(header: header, payload: .audioPathReady)
      )
      return
    }

    if let oldKey = connectionByMember[memberID], oldKey != entry.key {
      removePeer(oldKey, removesMember: false)
    }
    peer.isJoined = true
    peer.registrationLease = nil
    peer.lastSeenNanoseconds = MonotonicTime.nowNanoseconds()
    peers[entry.key] = peer
    connectionByMember[memberID] = entry.key
    unboundMemberDeadlines.removeValue(forKey: memberID)
    apply(.join(member), from: memberID, replyTo: peer.channel)
  }

  private func offerAudioPath(to key: ObjectIdentifier, rotatesToken: Bool) {
    guard var peer = peers[key], let audioPort else { return }
    let now = MonotonicTime.nowNanoseconds()
    let lease: AudioRegistrationLease
    if !rotatesToken, let existing = peer.registrationLease, existing.isActive(at: now) {
      lease = existing
    } else {
      lease = AudioRegistrationLease(
        issuedAtNanoseconds: now,
        lifetimeNanoseconds: Self.audioRegistrationLifetimeNanoseconds
      )
    }
    peer.registrationLease = lease
    peers[key] = peer
    peer.channel.send(
      ControlMessage(
        header: header,
        payload: .audioOffer(
          port: audioPort.rawValue,
          registrationToken: lease.token
        )
      ))
  }

  private func apply(
    _ command: RoomCommand,
    from sender: MemberID,
    replyTo channel: ControlChannel?
  ) {
    guard isRunning, reducer.snapshot.coordinatorID == localMemberID else { return }
    guard command.isAuthorized(for: sender) else { return }
    do {
      let events = try reducer.handle(command, nowNanoseconds: MonotonicTime.nowNanoseconds())
      audioRouter.updateRoute(reducer.snapshot)
      let departingKey: ObjectIdentifier?
      if case .leave(let memberID) = command {
        departingKey = connectionByMember.removeValue(forKey: memberID)
        unboundMemberDeadlines.removeValue(forKey: memberID)
        audioRouter.remove(memberID)
      } else {
        departingKey = nil
      }
      let isTelemetry: Bool
      if case .heartbeat = command { isTelemetry = true } else { isTelemetry = false }
      if !isTelemetry {
        if reducer.snapshot.coordinatorID == localMemberID {
          refreshAdvertisement()
        } else {
          controlListener?.service = nil
        }
      }
      for event in events {
        if isTelemetry, case .snapshot = event { continue }
        if case .memberAccepted = event, let channel {
          channel.send(eventMessage(event))
        } else {
          broadcast(eventMessage(event))
        }
        onEvent?(event)
      }
      if isTelemetry {
        scheduleTelemetrySnapshot()
      } else {
        onSnapshot?(reducer.snapshot)
      }
      if let departingKey {
        removePeer(departingKey, removesMember: false)
      }
    } catch {
      let event = RoomEvent.error(error.localizedDescription)
      if let channel {
        channel.send(eventMessage(event))
      } else {
        onError?(error.localizedDescription)
      }
    }
  }

  private func markActive(_ memberID: MemberID) {
    guard let key = connectionByMember[memberID], var peer = peers[key] else { return }
    peer.lastSeenNanoseconds = MonotonicTime.nowNanoseconds()
    peers[key] = peer
  }

  private func removePeer(_ key: ObjectIdentifier, removesMember: Bool) {
    guard let peer = peers.removeValue(forKey: key) else { return }
    guard let memberID = peer.candidate?.id else { return }
    if connectionByMember[memberID] == key {
      connectionByMember.removeValue(forKey: memberID)
    }
    audioRouter.remove(memberID)
    peer.channel.cancel()
    if removesMember, peer.isJoined, reducer.snapshot.contains(memberID),
      reducer.snapshot.coordinatorID == localMemberID
    {
      apply(.leave(memberID), from: memberID, replyTo: nil)
    }
  }

  private func startCleanupTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let now = MonotonicTime.nowNanoseconds()
      let stale = self.peers.filter {
        now &- $0.value.lastSeenNanoseconds > 5_000_000_000
      }
      for key in stale.keys {
        self.removePeer(key, removesMember: true)
      }
      let expiredUnboundMembers = self.unboundMemberDeadlines.compactMap { memberID, deadline in
        now >= deadline && self.connectionByMember[memberID] == nil ? memberID : nil
      }
      for memberID in expiredUnboundMembers where self.reducer.snapshot.contains(memberID) {
        self.unboundMemberDeadlines.removeValue(forKey: memberID)
        self.apply(.leave(memberID), from: memberID, replyTo: nil)
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
    guard advertisesRoom, let audioPort else { return }
    controlListener?.service = RoomAdvertisement.service(
      for: reducer.snapshot,
      audioPort: audioPort
    )
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
    for peer in peers.values where peer.isJoined {
      peer.channel.send(message)
    }
  }
}
