import Foundation

struct StreamStatistics: Sendable {
  let droppedFrames: UInt64
  let packetsSent: UInt64
  let peakLevel: Float
}

final class SystemAudioStreamer: @unchecked Sendable {
  static let packetFrames = 240
  static let playbackLatencyNanoseconds: UInt64 = 300_000_000

  private let queue = DispatchQueue(label: "com.zerosound.audio-stream", qos: .userInteractive)
  private let capture: SystemAudioCapture
  private let sourceID: MemberID
  private let streamGeneration: UInt64
  private let roomTime: @Sendable (UInt64) -> UInt64?
  private var timer: DispatchSourceTimer?
  private var sequence: UInt32 = 0
  private var lastStatisticsTime: UInt64 = 0
  private var packetsSent: UInt64 = 0
  private var peakSinceLastUpdate: Float = 0

  var onPacket: (@Sendable (AudioPacket) -> Void)?
  var onStatistics: (@Sendable (StreamStatistics) -> Void)?

  init(
    sourceID: MemberID,
    streamGeneration: UInt64,
    roomTime: @escaping @Sendable (UInt64) -> UInt64?
  ) throws {
    self.sourceID = sourceID
    self.streamGeneration = streamGeneration
    self.roomTime = roomTime
    capture = try SystemAudioCapture()
  }

  func start() throws -> Double {
    try capture.start()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      self?.drainCapture()
    }
    timer.resume()
    self.timer = timer
    return capture.sampleRate
  }

  func stop() {
    timer?.cancel()
    timer = nil
    capture.stop()
  }

  private func drainCapture() {
    var packetsDrained = 0
    while packetsDrained < 16,
      let chunk = capture.read(maximumFrames: Self.packetFrames)
    {
      sequence &+= 1
      let captureNanoseconds = MonotonicTime.ticksToNanoseconds(chunk.firstHostTime)
      guard
        let presentationTime = roomTime(
          captureNanoseconds + Self.playbackLatencyNanoseconds)
      else { break }
      let packet = AudioPacket(
        sequence: sequence,
        presentationNanoseconds: presentationTime,
        sampleRate: UInt32(capture.sampleRate.rounded()),
        streamGeneration: streamGeneration,
        sourceID: sourceID,
        floatSamples: chunk.samples
      )
      packetsSent &+= 1
      let peak = chunk.samples.reduce(Float.zero) { max($0, abs($1)) }
      peakSinceLastUpdate = max(peakSinceLastUpdate, peak)
      onPacket?(packet)
      packetsDrained += 1
    }
    let now = MonotonicTime.nowNanoseconds()
    if now - lastStatisticsTime >= 1_000_000_000 {
      lastStatisticsTime = now
      onStatistics?(
        StreamStatistics(
          droppedFrames: capture.droppedFrameCount,
          packetsSent: packetsSent,
          peakLevel: peakSinceLastUpdate
        )
      )
      peakSinceLastUpdate = 0
    }
  }
}
