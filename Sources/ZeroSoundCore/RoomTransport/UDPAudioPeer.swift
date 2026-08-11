import Foundation
@preconcurrency import Network

/// Member-owned UDP data plane. Audio delivery and clock sampling can lose datagrams without
/// affecting the reliable control connection or room membership.
final class UDPAudioPeer: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.zerosound.udp-audio-peer",
    qos: .userInteractive
  )
  private let endpoint: NWEndpoint
  private let registration: AudioPlaneRegistration
  private var connection: NWConnection?
  private var registrationTimer: DispatchSourceTimer?
  private var pingTimer: DispatchSourceTimer?
  private var sequence: UInt64 = 0
  private var audioSendWindow = BoundedDatagramSendWindow()
  private var lastReceiveNanoseconds: UInt64 = 0
  private var isStopped = true
  private var hasFailed = false

  var onAudio: (@Sendable (AudioPacket) -> Void)?
  var onClockSample: (@Sendable (ClockSample) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  var onSendDrops: (@Sendable (UInt64) -> Void)?

  init(endpoint: NWEndpoint, registration: AudioPlaneRegistration) {
    self.endpoint = endpoint
    self.registration = registration
  }

  func start() {
    queue.async { [self] in startOnQueue() }
  }

  private func startOnQueue() {
    isStopped = false
    hasFailed = false
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    let connection = NWConnection(to: endpoint, using: parameters)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      guard self.connection === connection else { return }
      switch state {
      case .ready:
        self.lastReceiveNanoseconds = MonotonicTime.nowNanoseconds()
        self.startRegistering(on: connection)
        self.startPinging(on: connection)
      case .failed(let error):
        self.fail("Audio connection failed: \(error.localizedDescription)", on: connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    self.connection = connection
    receive(on: connection)
  }

  func stop() {
    queue.async { [self] in stopOnQueue() }
  }

  private func stopOnQueue() {
    isStopped = true
    registrationTimer?.cancel()
    registrationTimer = nil
    pingTimer?.cancel()
    pingTimer = nil
    connection?.cancel()
    connection = nil
    audioSendWindow.reset()
    lastReceiveNanoseconds = 0
  }

  func sendAudio(_ packet: AudioPacket) {
    let data = packet.encode()
    queue.async { [self] in enqueueAudio(data) }
  }

  func markRegistered() {
    queue.async { [self] in
      registrationTimer?.cancel()
      registrationTimer = nil
    }
  }

  private func startRegistering(on connection: NWConnection) {
    registrationTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self, weak connection] in
      guard let self, let connection else { return }
      self.sendRegistration(on: connection)
    }
    timer.resume()
    registrationTimer = timer
  }

  private func sendRegistration(on connection: NWConnection) {
    let message = AudioPlaneControl.register(
      roomID: registration.roomID,
      memberID: registration.memberID,
      coordinatorTerm: registration.coordinatorTerm,
      token: registration.token
    )
    guard let data = try? AudioPlaneControlCodec.encode(message) else { return }
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  private func enqueueAudio(_ data: Data) {
    guard let connection else { return }
    let previousDrops = audioSendWindow.droppedDatagrams
    let admitted = audioSendWindow.beginSend()
    if audioSendWindow.droppedDatagrams != previousDrops {
      onSendDrops?(audioSendWindow.droppedDatagrams)
    }
    guard admitted else { return }
    sendAudioNow(data, on: connection)
  }

  private func sendAudioNow(_ data: Data, on connection: NWConnection) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self, weak connection] error in
        guard let self, let connection else { return }
        self.queue.async {
          guard self.connection === connection else { return }
          self.audioSendWindow.completeSend()
          if let error {
            self.fail("Audio send failed: \(error.localizedDescription)", on: connection)
          }
        }
      })
  }

  private func startPinging(on connection: NWConnection) {
    pingTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(500))
    timer.setEventHandler { [weak self, weak connection] in
      guard let self, let connection else { return }
      let now = MonotonicTime.nowNanoseconds()
      if now &- self.lastReceiveNanoseconds > 3_000_000_000 {
        self.fail("Audio path stopped responding.", on: connection)
        return
      }
      self.sequence &+= 1
      let ping = AudioPlaneControl.clockPing(
        sequence: self.sequence,
        clientSendNanoseconds: MonotonicTime.nowNanoseconds()
      )
      guard let data = try? AudioPlaneControlCodec.encode(ping) else { return }
      connection.send(content: data, completion: .contentProcessed { _ in })
    }
    timer.resume()
    pingTimer = timer
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] data, _, _, error in
      guard let self, let connection else { return }
      guard self.connection === connection else { return }
      if let data, !data.isEmpty {
        if let packet = AudioPacket.decode(data) {
          self.lastReceiveNanoseconds = MonotonicTime.nowNanoseconds()
          self.onAudio?(packet)
        } else if let control = try? AudioPlaneControlCodec.decode(data),
          case .clockPong(
            _, let clientSend, let coordinatorReceive, let coordinatorSend) = control
        {
          self.lastReceiveNanoseconds = MonotonicTime.nowNanoseconds()
          self.onClockSample?(
            ClockSample(
              clientSend: clientSend,
              coordinatorReceive: coordinatorReceive,
              coordinatorSend: coordinatorSend,
              clientReceive: MonotonicTime.nowNanoseconds()
            ))
        }
      }
      if error == nil {
        self.receive(on: connection)
      } else {
        self.fail("Audio connection interrupted: \(error!.localizedDescription)", on: connection)
      }
    }
  }

  private func fail(_ reason: String, on connection: NWConnection) {
    guard !isStopped, !hasFailed, self.connection === connection else { return }
    hasFailed = true
    registrationTimer?.cancel()
    registrationTimer = nil
    pingTimer?.cancel()
    pingTimer = nil
    self.connection = nil
    audioSendWindow.reset()
    connection.cancel()
    onError?(reason)
  }
}
