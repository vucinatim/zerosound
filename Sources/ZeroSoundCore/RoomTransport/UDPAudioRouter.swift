import Foundation
@preconcurrency import Network

/// Coordinator-owned UDP data plane. It routes audio and low-latency clock samples only; room
/// membership and authorization remain owned by the reliable control session.
final class UDPAudioRouter: @unchecked Sendable {
  private struct AudioRoute: Equatable {
    let sourceID: MemberID
    let generation: UInt64

    init?(snapshot: RoomSnapshot) {
      guard case .live(let sourceID) = snapshot.audioSource else { return nil }
      self.sourceID = sourceID
      generation = snapshot.streamGeneration
    }

    func accepts(_ packet: AudioPacket, from memberID: MemberID) -> Bool {
      memberID == sourceID
        && packet.sourceID == sourceID
        && packet.streamGeneration == generation
    }
  }

  private struct UnidentifiedConnection {
    let connection: NWConnection
    let acceptedAtNanoseconds: UInt64
  }

  private struct Peer {
    let connection: NWConnection
    var audioSendQueue = LatestValueSendQueue<Data>()
  }

  private let queue = DispatchQueue(
    label: "com.zerosound.udp-audio-router",
    qos: .userInteractive
  )
  private let lifecycleLock = NSLock()
  private var isAcceptingTraffic = false
  private var listener: NWListener?
  private var unidentified: [ObjectIdentifier: UnidentifiedConnection] = [:]
  private var peers: [MemberID: Peer] = [:]
  private var droppedAudioDatagrams: UInt64 = 0
  private var cleanupTimer: DispatchSourceTimer?
  private var dropReportTimer: DispatchSourceTimer?
  private var audioRoute: AudioRoute?
  private var routedGeneration: UInt64?
  private var routedSampleRate: UInt32?

  var validatesRegistration: (@Sendable (AudioPlaneRegistration) -> Bool)?
  var onRegistered: (@Sendable (MemberID) -> Void)?
  var onRoutedAudio: (@Sendable (AudioPacket) -> Void)?
  var onStreamFormat: (@Sendable (UInt32) -> Void)?
  var onPeerActivity: (@Sendable (MemberID) -> Void)?
  var onReady: (@Sendable (NWEndpoint.Port) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  var onSendDrops: (@Sendable (UInt64) -> Void)?

  func start() throws {
    do {
      try queue.sync { try startOnQueue() }
    } catch {
      setAcceptingTraffic(false)
      throw error
    }
  }

  private func startOnQueue() throws {
    setAcceptingTraffic(true)
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    let listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard let self else { return }
      switch state {
      case .ready:
        guard self.acceptsTraffic else { return }
        guard let port = listener?.port else { return }
        self.onReady?(port)
      case .failed(let error):
        self.onError?("Audio listener failed: \(error.localizedDescription)")
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
    startCleanupTimer()
  }

  func stop() {
    setAcceptingTraffic(false)
    queue.async { [self] in
      listener?.cancel()
      listener = nil
      cleanupTimer?.cancel()
      cleanupTimer = nil
      dropReportTimer?.cancel()
      dropReportTimer = nil
      for peer in peers.values { peer.connection.cancel() }
      peers.removeAll()
      droppedAudioDatagrams = 0
      audioRoute = nil
      routedGeneration = nil
      routedSampleRate = nil
      for entry in unidentified.values { entry.connection.cancel() }
      unidentified.removeAll()
    }
  }

  func updateRoute(_ snapshot: RoomSnapshot) {
    let route = AudioRoute(snapshot: snapshot)
    queue.async { [self] in
      if audioRoute != route {
        routedGeneration = nil
        routedSampleRate = nil
      }
      audioRoute = route
    }
  }

  func routeAudio(_ packet: AudioPacket, from memberID: MemberID) {
    queue.async { [self] in routeAudioOnQueue(packet, from: memberID) }
  }

  func remove(_ memberID: MemberID) {
    queue.async { [self] in
      peers.removeValue(forKey: memberID)?.connection.cancel()
    }
  }

  private func accept(_ connection: NWConnection) {
    guard unidentified.count < 16 else {
      connection.cancel()
      return
    }
    unidentified[ObjectIdentifier(connection)] = UnidentifiedConnection(
      connection: connection,
      acceptedAtNanoseconds: MonotonicTime.nowNanoseconds()
    )
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .failed, .cancelled:
        self.remove(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else { return }
      if let data, !data.isEmpty {
        self.handle(data, on: connection)
      }
      if error == nil {
        self.receive(on: connection)
      } else {
        self.remove(connection)
      }
    }
  }

  private func handle(_ data: Data, on connection: NWConnection) {
    guard acceptsTraffic else { return }
    if let packet = AudioPacket.decode(data) {
      guard let memberID = memberID(for: connection) else { return }
      routeAudioOnQueue(packet, from: memberID)
      return
    }

    guard let control = try? AudioPlaneControlCodec.decode(data) else { return }
    switch control {
    case .register(let roomID, let memberID, let term, let token):
      if self.memberID(for: connection) == memberID {
        onPeerActivity?(memberID)
        return
      }
      let registration = AudioPlaneRegistration(
        roomID: roomID,
        memberID: memberID,
        coordinatorTerm: term,
        token: token
      )
      guard validatesRegistration?(registration) == true else {
        connection.cancel()
        return
      }
      register(connection, for: memberID)
      onRegistered?(memberID)

    case .clockPing(let sequence, let clientSend):
      guard let memberID = memberID(for: connection) else { return }
      onPeerActivity?(memberID)
      let received = MonotonicTime.nowNanoseconds()
      let response = AudioPlaneControl.clockPong(
        sequence: sequence,
        clientSendNanoseconds: clientSend,
        coordinatorReceiveNanoseconds: received,
        coordinatorSendNanoseconds: MonotonicTime.nowNanoseconds()
      )
      guard let encoded = try? AudioPlaneControlCodec.encode(response) else { return }
      connection.send(content: encoded, completion: .contentProcessed { _ in })

    case .clockPong:
      break
    }
  }

  private func register(_ connection: NWConnection, for memberID: MemberID) {
    unidentified.removeValue(forKey: ObjectIdentifier(connection))
    if let previous = peers[memberID], previous.connection !== connection {
      previous.connection.cancel()
    }
    peers[memberID] = Peer(connection: connection)
  }

  private func memberID(for connection: NWConnection) -> MemberID? {
    peers.first { $0.value.connection === connection }?.key
  }

  private func remove(_ connection: NWConnection) {
    unidentified.removeValue(forKey: ObjectIdentifier(connection))
    if let memberID = memberID(for: connection) {
      peers.removeValue(forKey: memberID)
    }
  }

  private func startCleanupTimer() {
    cleanupTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let now = MonotonicTime.nowNanoseconds()
      let staleConnections = self.unidentified.values.compactMap { entry in
        now &- entry.acceptedAtNanoseconds > 5_000_000_000 ? entry.connection : nil
      }
      for connection in staleConnections {
        connection.cancel()
        self.unidentified.removeValue(forKey: ObjectIdentifier(connection))
      }
    }
    timer.resume()
    cleanupTimer = timer
  }

  private func enqueueAudio(_ data: Data, for memberID: MemberID) {
    guard var peer = peers[memberID] else { return }
    let previousDrops = peer.audioSendQueue.droppedValues
    let immediate = peer.audioSendQueue.enqueue(data)
    if peer.audioSendQueue.droppedValues != previousDrops {
      droppedAudioDatagrams &+= peer.audioSendQueue.droppedValues &- previousDrops
      scheduleDropReport()
    }
    peers[memberID] = peer
    if let immediate {
      sendAudioNow(immediate, to: memberID, on: peer.connection)
    }
  }

  private func routeAudioOnQueue(_ packet: AudioPacket, from memberID: MemberID) {
    guard acceptsTraffic, audioRoute?.accepts(packet, from: memberID) == true else { return }
    if routedGeneration != packet.streamGeneration || routedSampleRate != packet.sampleRate {
      routedGeneration = packet.streamGeneration
      routedSampleRate = packet.sampleRate
      onStreamFormat?(packet.sampleRate)
    }
    let data = packet.encode()
    for peerID in peers.keys { enqueueAudio(data, for: peerID) }
    onRoutedAudio?(packet)
  }

  private func scheduleDropReport() {
    guard dropReportTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(500))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.dropReportTimer?.cancel()
      self.dropReportTimer = nil
      self.onSendDrops?(self.droppedAudioDatagrams)
    }
    timer.resume()
    dropReportTimer = timer
  }

  private var acceptsTraffic: Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return isAcceptingTraffic
  }

  private func setAcceptingTraffic(_ value: Bool) {
    lifecycleLock.lock()
    isAcceptingTraffic = value
    lifecycleLock.unlock()
  }

  private func sendAudioNow(
    _ data: Data,
    to memberID: MemberID,
    on connection: NWConnection
  ) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self, weak connection] error in
        guard let self, let connection else { return }
        self.queue.async {
          guard var peer = self.peers[memberID], peer.connection === connection else { return }
          if error != nil {
            self.remove(connection)
            return
          }
          let next = peer.audioSendQueue.didComplete()
          self.peers[memberID] = peer
          if let next {
            self.sendAudioNow(next, to: memberID, on: connection)
          }
        }
      })
  }
}

struct AudioPlaneRegistration: Equatable, Sendable {
  let roomID: RoomID
  let memberID: MemberID
  let coordinatorTerm: UInt64
  let token: UUID
}
