import Foundation

protocol RoomClock: Sendable {
  func nowNanoseconds() -> UInt64
}

struct FixedRoomClock: RoomClock {
  var now: UInt64
  func nowNanoseconds() -> UInt64 { now }
}

/// Deterministic integration transport for room behavior. It deliberately models only delivery
/// semantics; production Bonjour and UDP remain outside core correctness tests.
struct InProcessRoomTransport: Sendable {
  enum NextDelivery: Sendable {
    case reliable
    case drop
    case duplicate
    case hold
  }

  private(set) var reducer: RoomStateMachine
  private let clock: any RoomClock
  private(set) var deliveredEvents: [RoomEvent] = []
  private(set) var deliveredAudio: [AudioPacket] = []
  private var heldEvents: [RoomEvent] = []
  private var heldAudio: [AudioPacket] = []
  var nextControlDelivery: NextDelivery = .reliable
  var nextAudioDelivery: NextDelivery = .reliable

  init(snapshot: RoomSnapshot, clock: any RoomClock) {
    reducer = RoomStateMachine(snapshot: snapshot)
    self.clock = clock
  }

  mutating func send(_ command: RoomCommand) throws {
    let events = try reducer.handle(command, nowNanoseconds: clock.nowNanoseconds())
    deliver(events, using: nextControlDelivery)
    nextControlDelivery = .reliable
  }

  @discardableResult
  mutating func sendAudio(_ packet: AudioPacket) -> Bool {
    guard AudioPacketFence.accepts(packet, snapshot: reducer.snapshot) else { return false }
    deliver([packet], using: nextAudioDelivery)
    nextAudioDelivery = .reliable
    return true
  }

  mutating func flushHeldInReverseOrder() {
    deliveredEvents.append(contentsOf: heldEvents.reversed())
    deliveredAudio.append(
      contentsOf: heldAudio.reversed().filter {
        AudioPacketFence.accepts($0, snapshot: reducer.snapshot)
      })
    heldEvents.removeAll(keepingCapacity: true)
    heldAudio.removeAll(keepingCapacity: true)
  }

  private mutating func deliver(_ events: [RoomEvent], using delivery: NextDelivery) {
    switch delivery {
    case .reliable: appendBounded(events, to: &deliveredEvents)
    case .drop: break
    case .duplicate:
      appendBounded(events, to: &deliveredEvents)
      appendBounded(events, to: &deliveredEvents)
    case .hold: appendBounded(events, to: &heldEvents)
    }
  }

  private mutating func deliver(_ packets: [AudioPacket], using delivery: NextDelivery) {
    switch delivery {
    case .reliable: appendBounded(packets, to: &deliveredAudio)
    case .drop: break
    case .duplicate:
      appendBounded(packets, to: &deliveredAudio)
      appendBounded(packets, to: &deliveredAudio)
    case .hold: appendBounded(packets, to: &heldAudio)
    }
  }

  private func appendBounded<T>(_ values: [T], to destination: inout [T]) {
    destination.append(contentsOf: values)
    if destination.count > 2_048 {
      destination.removeFirst(destination.count - 2_048)
    }
  }
}
