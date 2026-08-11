import Foundation

/// A single-flight, one-pending-value queue for real-time datagrams.
///
/// When the network cannot complete sends at the production rate, stale audio is replaced by the
/// newest packet instead of allowing latency and memory usage to grow without bound.
struct LatestValueSendQueue<Value: Sendable>: Sendable {
  private var isSending = false
  private var pendingLatest: Value?
  private(set) var droppedValues: UInt64 = 0

  mutating func enqueue(_ value: Value) -> Value? {
    guard isSending else {
      isSending = true
      return value
    }
    if pendingLatest != nil { droppedValues &+= 1 }
    pendingLatest = value
    return nil
  }

  mutating func didComplete() -> Value? {
    if let pendingLatest {
      self.pendingLatest = nil
      return pendingLatest
    }
    isSending = false
    return nil
  }

  mutating func reset() {
    isSending = false
    pendingLatest = nil
  }
}
