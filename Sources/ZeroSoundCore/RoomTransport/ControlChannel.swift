import Foundation
@preconcurrency import Network

/// One framed, ordered control stream. The owner supplies a serial queue and remains responsible for
/// room/session state; this type owns only stream framing and connection lifecycle.
final class ControlChannel: @unchecked Sendable {
  let connection: NWConnection

  private let queue: DispatchQueue
  private var decoder = ControlFrameDecoder()
  private var isClosed = false

  var onReady: (@Sendable () -> Void)?
  var onMessage: (@Sendable (ControlMessage) -> Void)?
  var onClose: (@Sendable (String) -> Void)?

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.onReady?()
      case .failed(let error):
        self.close(error.localizedDescription)
      case .cancelled:
        self.close("Control connection closed.")
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  func send(_ message: ControlMessage, completion: (@Sendable () -> Void)? = nil) {
    guard !isClosed else { return }
    do {
      let frame = try ControlFrameCodec.encode(ControlCodec.encode(message))
      connection.send(
        content: frame,
        completion: .contentProcessed { [weak self] error in
          self?.queue.async { [weak self] in
            if let error {
              self?.close(error.localizedDescription)
            }
            completion?()
          }
        })
    } catch {
      close("Control encoding failed: \(error.localizedDescription)")
      completion?()
    }
  }

  func cancel() {
    guard !isClosed else { return }
    isClosed = true
    connection.cancel()
  }

  private func receive() {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1_024
    ) { [weak self] data, _, isComplete, error in
      guard let self, !self.isClosed else { return }
      do {
        if let data, !data.isEmpty {
          for payload in try self.decoder.append(data) {
            self.onMessage?(try ControlCodec.decode(payload))
          }
        }
        if let error {
          self.close(error.localizedDescription)
        } else if isComplete {
          try self.decoder.finish()
          self.close("Control connection closed.")
        } else {
          self.receive()
        }
      } catch {
        self.close("Invalid control stream: \(error.localizedDescription)")
      }
    }
  }

  private func close(_ reason: String) {
    guard !isClosed else { return }
    isClosed = true
    connection.cancel()
    onClose?(reason)
  }
}
