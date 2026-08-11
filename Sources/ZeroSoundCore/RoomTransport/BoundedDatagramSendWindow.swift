import Foundation

/// Bounds memory without serializing independent UDP datagrams behind completion callbacks.
///
/// Network.framework may complete a send several milliseconds after accepting it. Treating that
/// callback as permission to submit the next datagram creates artificial packet loss at normal
/// audio rates. A small in-flight window preserves datagram cadence while still applying a hard
/// upper bound if the local network stack stalls.
struct BoundedDatagramSendWindow: Sendable {
  private let maximumInFlight: Int
  private(set) var inFlight = 0
  private(set) var droppedDatagrams: UInt64 = 0

  init(maximumInFlight: Int = 64) {
    self.maximumInFlight = max(1, maximumInFlight)
  }

  mutating func beginSend() -> Bool {
    guard inFlight < maximumInFlight else {
      droppedDatagrams &+= 1
      return false
    }
    inFlight += 1
    return true
  }

  mutating func completeSend() {
    if inFlight > 0 { inFlight -= 1 }
  }

  mutating func reset() {
    inFlight = 0
  }
}
