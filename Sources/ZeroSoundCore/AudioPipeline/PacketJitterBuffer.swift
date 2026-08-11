import Foundation

struct TimedAudioPacket: Sendable {
  let packet: AudioPacket
  let localPresentationNanoseconds: UInt64
}

struct RenderChunk: Sendable {
  let sequence: UInt32
  let samples: [Int16]
  let roomPresentationNanoseconds: UInt64
  let localPresentationNanoseconds: UInt64
  let desiredPresentationNanoseconds: UInt64?
  let isConcealed: Bool

  var frameCount: Int { samples.count / 2 }
}

struct JitterBufferStatistics: Equatable, Sendable {
  var missingPackets: UInt64 = 0
  var concealedFrames: UInt64 = 0
  var latePackets: UInt64 = 0
  var reorderedPackets: UInt64 = 0
  var duplicatePackets: UInt64 = 0
}

struct PacketJitterBuffer: Sendable {
  static let schedulingLeadNanoseconds: UInt64 = 25_000_000

  private let maximumPendingPackets: Int
  private var pending: [UInt32: TimedAudioPacket] = [:]
  private var nextSequence: UInt32?
  private var nextPresentationNanoseconds: UInt64?
  private var packetDurationNanoseconds: UInt64 = 0
  private var frameCount = 0
  private var sampleRate: UInt32 = 0
  private var previousFrame: (left: Int16, right: Int16)?
  private var highestReceivedSequence: UInt32?
  private var startupDeadlineNanoseconds: UInt64?
  private var gapDeadlineNanoseconds: UInt64?
  private var hasStarted = false

  private(set) var statistics = JitterBufferStatistics()

  init(maximumPendingPackets: Int = 256) {
    self.maximumPendingPackets = max(8, maximumPendingPackets)
  }

  mutating func insert(
    _ timedPacket: TimedAudioPacket,
    nowNanoseconds: UInt64
  ) -> [RenderChunk] {
    let packet = timedPacket.packet
    guard packet.frameCount > 0 else { return [] }

    if nextSequence == nil {
      configureTimeline(from: timedPacket)
    } else if packet.sampleRate != sampleRate || packet.frameCount != frameCount {
      reset()
      configureTimeline(from: timedPacket)
    }

    guard let expected = nextSequence else { return [] }
    var distance = forwardDistance(from: expected, to: packet.sequence)
    if distance >= UInt32.max / 2, !hasStarted {
      let backwardDistance = forwardDistance(from: packet.sequence, to: expected)
      guard backwardDistance < UInt32(maximumPendingPackets) else {
        statistics.latePackets &+= 1
        return []
      }
      nextSequence = packet.sequence
      nextPresentationNanoseconds = timedPacket.localPresentationNanoseconds
      startupDeadlineNanoseconds = decisionDeadline(
        forPresentationNanoseconds: timedPacket.localPresentationNanoseconds
      )
      distance = 0
    } else if distance >= UInt32.max / 2 {
      statistics.latePackets &+= 1
      return []
    }
    if pending[packet.sequence] != nil {
      statistics.duplicatePackets &+= 1
      return []
    }
    guard distance < UInt32(maximumPendingPackets) else {
      statistics.latePackets &+= 1
      return []
    }

    if let highestReceivedSequence {
      let distanceFromHighest = forwardDistance(
        from: highestReceivedSequence,
        to: packet.sequence
      )
      if distanceFromHighest >= UInt32.max / 2 {
        statistics.reorderedPackets &+= 1
      } else if distanceFromHighest > 0 {
        self.highestReceivedSequence = packet.sequence
      }
    } else {
      highestReceivedSequence = packet.sequence
    }

    pending[packet.sequence] = timedPacket
    return drain(nowNanoseconds: nowNanoseconds)
  }

  mutating func drain(nowNanoseconds: UInt64) -> [RenderChunk] {
    if !hasStarted {
      guard nextSequence != nil,
        nowNanoseconds >= startupDeadlineNanoseconds ?? 0
      else { return [] }
      hasStarted = true
    }

    var output: [RenderChunk] = []

    while let expected = nextSequence,
      let presentation = nextPresentationNanoseconds
    {
      if let timedPacket = pending.removeValue(forKey: expected) {
        gapDeadlineNanoseconds = nil
        output.append(realChunk(from: timedPacket, timelinePresentation: presentation))
        advanceTimeline()
        continue
      }

      guard let nearest = nearestFuturePacket(after: expected) else {
        gapDeadlineNanoseconds = nil
        break
      }

      if gapDeadlineNanoseconds == nil {
        gapDeadlineNanoseconds = decisionDeadline(
          forPresentationNanoseconds: presentation
        )
      }
      guard nowNanoseconds >= gapDeadlineNanoseconds ?? 0 else { break }

      let missingCount = Int(forwardDistance(from: expected, to: nearest.packet.sequence))
      guard missingCount > 0 else { break }
      gapDeadlineNanoseconds = nil
      output.append(contentsOf: concealedChunks(count: missingCount, before: nearest))
    }

    return output
  }

  mutating func reset() {
    pending.removeAll(keepingCapacity: true)
    nextSequence = nil
    nextPresentationNanoseconds = nil
    packetDurationNanoseconds = 0
    frameCount = 0
    sampleRate = 0
    previousFrame = nil
    highestReceivedSequence = nil
    startupDeadlineNanoseconds = nil
    gapDeadlineNanoseconds = nil
    hasStarted = false
    statistics = JitterBufferStatistics()
  }

  private mutating func configureTimeline(from timedPacket: TimedAudioPacket) {
    let packet = timedPacket.packet
    nextSequence = packet.sequence
    nextPresentationNanoseconds = timedPacket.localPresentationNanoseconds
    frameCount = packet.frameCount
    sampleRate = packet.sampleRate
    packetDurationNanoseconds = UInt64(
      (Double(packet.frameCount) * 1_000_000_000 / Double(packet.sampleRate)).rounded()
    )
    startupDeadlineNanoseconds = decisionDeadline(
      forPresentationNanoseconds: timedPacket.localPresentationNanoseconds
    )
  }

  private mutating func realChunk(
    from timedPacket: TimedAudioPacket,
    timelinePresentation: UInt64
  ) -> RenderChunk {
    let samples = timedPacket.packet.samples
    previousFrame = (samples[samples.count - 2], samples[samples.count - 1])
    return RenderChunk(
      sequence: timedPacket.packet.sequence,
      samples: samples,
      roomPresentationNanoseconds: timedPacket.packet.presentationNanoseconds,
      localPresentationNanoseconds: timelinePresentation,
      desiredPresentationNanoseconds: timedPacket.localPresentationNanoseconds,
      isConcealed: false
    )
  }

  private mutating func concealedChunks(
    count: Int,
    before futurePacket: TimedAudioPacket
  ) -> [RenderChunk] {
    guard
      let expected = nextSequence,
      let presentation = nextPresentationNanoseconds
    else { return [] }

    let futureSamples = futurePacket.packet.samples
    let start = previousFrame ?? (0, 0)
    let end = (futureSamples[0], futureSamples[1])
    let totalFrames = count * frameCount
    var chunks: [RenderChunk] = []
    chunks.reserveCapacity(count)

    for packetIndex in 0..<count {
      var samples = [Int16]()
      samples.reserveCapacity(frameCount * 2)
      for frame in 0..<frameCount {
        let absoluteFrame = packetIndex * frameCount + frame + 1
        let progress = Double(absoluteFrame) / Double(totalFrames + 1)
        samples.append(interpolate(from: start.0, to: end.0, progress: progress))
        samples.append(interpolate(from: start.1, to: end.1, progress: progress))
      }
      chunks.append(
        RenderChunk(
          sequence: expected &+ UInt32(packetIndex),
          samples: samples,
          roomPresentationNanoseconds:
            futurePacket.packet.presentationNanoseconds
            &- UInt64(count - packetIndex) * packetDurationNanoseconds,
          localPresentationNanoseconds:
            presentation &+ UInt64(packetIndex) &* packetDurationNanoseconds,
          desiredPresentationNanoseconds: nil,
          isConcealed: true
        )
      )
    }

    previousFrame = chunks.last.map { chunk in
      (chunk.samples[chunk.samples.count - 2], chunk.samples[chunk.samples.count - 1])
    }
    statistics.missingPackets &+= UInt64(count)
    statistics.concealedFrames &+= UInt64(count * frameCount)
    for _ in 0..<count {
      advanceTimeline()
    }
    return chunks
  }

  private func nearestFuturePacket(after expected: UInt32) -> TimedAudioPacket? {
    pending.values.min {
      forwardDistance(from: expected, to: $0.packet.sequence)
        < forwardDistance(from: expected, to: $1.packet.sequence)
    }
  }

  private mutating func advanceTimeline() {
    nextSequence = nextSequence.map { $0 &+ 1 }
    nextPresentationNanoseconds = nextPresentationNanoseconds.map {
      $0 &+ packetDurationNanoseconds
    }
  }

  /// The last instant at which a scheduling decision can be made without risking an underrun.
  ///
  /// Packets are intentionally allowed to reorder for the entire available playout budget. A
  /// short wall-clock timeout would discard delayed packets even while hundreds of milliseconds
  /// of already-buffered audio remain available.
  private func decisionDeadline(forPresentationNanoseconds presentation: UInt64) -> UInt64 {
    presentation > Self.schedulingLeadNanoseconds
      ? presentation - Self.schedulingLeadNanoseconds : 0
  }
}

private func forwardDistance(from start: UInt32, to end: UInt32) -> UInt32 {
  end &- start
}

private func interpolate(from start: Int16, to end: Int16, progress: Double) -> Int16 {
  let value = Double(start) + (Double(end) - Double(start)) * progress
  return Int16(clamping: Int(value.rounded()))
}
