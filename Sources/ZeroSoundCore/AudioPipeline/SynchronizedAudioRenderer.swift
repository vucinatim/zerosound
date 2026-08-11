@preconcurrency import AVFAudio
import Foundation

final class SynchronizedAudioRenderer: @unchecked Sendable {
  private static let packetsPerRenderBuffer = 4
  private static let fadeInMilliseconds = 5
  private static let statisticsIntervalNanoseconds: UInt64 = 500_000_000

  private let queue = DispatchQueue(label: "com.zerosound.audio-renderer", qos: .userInteractive)
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let varispeed = AVAudioUnitVarispeed()

  private var jitterBuffer = PacketJitterBuffer()
  private var phaseController = PlaybackPhaseController()
  private var rollingEvents = RollingPlaybackEvents()
  private var playbackState = SynchronizedPlaybackState()
  private let startPlanner = PlaybackStartPlanner()
  private let reanchorPlanner = PlaybackReanchorPlanner()
  private var streamTimeline: StreamTimeline?
  private var nextScheduledPlayerSampleTime: Int64?
  private var configuredSampleRate: UInt32?
  private var renderBatchFrames = 0
  private var accumulatedSamples: [Int16] = []
  private var accumulatedPresentationNanoseconds: UInt64?
  private var accumulatedRoomPresentationNanoseconds: UInt64?
  private var scheduledFrames: UInt64 = 0
  private var scheduledBatches: [ScheduledAudioBatch] = []
  private var nextScheduledBatchID: UInt64 = 0
  private var renderGeneration: UInt64 = 0
  private var fadeInFramesRemaining = 0
  private var fadeInTotalFrames = 0
  private var rendererUnderruns: UInt64 = 0
  private var resynchronizations: UInt64 = 0
  private var phaseResynchronizations: UInt64 = 0
  private var pendingPhaseResynchronization = false
  private var lastRecoveryReason: String?
  private var discardedPackets: UInt64 = 0
  private var isAcceptingAudio = false
  private var lastStatisticsTime: UInt64 = 0
  private var outputPresentationLatencyNanoseconds: UInt64 = 0
  private var lastPhaseObservationNanoseconds: UInt64 = 0
  private var configurationObserver: NSObjectProtocol?
  private var roomClockMapping = RoomClockMapping.identity

  var onStatistics: (@Sendable (PlaybackHealth) -> Void)?

  init() {
    engine.attach(player)
    engine.attach(varispeed)
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.recoverFromEngineConfigurationChange()
      }
    }
  }

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
  }

  func enqueue(_ packet: AudioPacket, roomClockMapping: RoomClockMapping) {
    queue.async { [self] in
      do {
        self.roomClockMapping = roomClockMapping
        guard
          let localPresentationNanoseconds = roomClockMapping.localTime(
            forRoomTime: packet.presentationNanoseconds)
        else { return }
        try configureIfNeeded(sampleRate: packet.sampleRate, packetFrames: packet.frameCount)
        isAcceptingAudio = true
        let chunks = jitterBuffer.insert(
          TimedAudioPacket(
            packet: packet,
            localPresentationNanoseconds: localPresentationNanoseconds
          ),
          nowNanoseconds: MonotonicTime.nowNanoseconds()
        )
        process(chunks, sampleRate: packet.sampleRate)
        publishStatisticsIfNeeded()
      } catch {
        stopOnQueue()
      }
    }
  }

  func stop() {
    queue.async { [self] in
      stopOnQueue()
    }
  }

  private func process(_ chunks: [RenderChunk], sampleRate: UInt32) {
    for chunk in chunks {
      switch playbackState.phase {
      case .awaitingAnchor, .recovering:
        guard
          !chunk.isConcealed,
          let desiredPresentation = chunk.desiredPresentationNanoseconds,
          playbackState.considerAnchor(
            presentationNanoseconds: desiredPresentation,
            nowNanoseconds: MonotonicTime.nowNanoseconds()
          )
        else {
          discardedPackets &+= 1
          continue
        }
        beginPriming(sampleRate: sampleRate)

      case .priming, .playing:
        break
      }

      if accumulatedSamples.isEmpty {
        accumulatedPresentationNanoseconds =
          playbackState.selectedAnchorNanoseconds
          ?? roomClockMapping.localTime(forRoomTime: chunk.roomPresentationNanoseconds)
          ?? chunk.localPresentationNanoseconds
        accumulatedRoomPresentationNanoseconds = chunk.roomPresentationNanoseconds
      }
      accumulatedSamples.append(contentsOf: chunk.samples)
      scheduleCompleteBatches(sampleRate: sampleRate)
    }
    observePlaybackPhaseIfNeeded()
  }

  private func beginPriming(sampleRate: UInt32) {
    accumulatedSamples.removeAll(keepingCapacity: true)
    accumulatedPresentationNanoseconds = playbackState.selectedAnchorNanoseconds
    accumulatedRoomPresentationNanoseconds = nil
    phaseController.reset()
    streamTimeline = nil
    nextScheduledPlayerSampleTime = nil
    lastPhaseObservationNanoseconds = 0
    varispeed.rate = 1
    fadeInTotalFrames = max(1, Int(sampleRate) * Self.fadeInMilliseconds / 1_000)
    fadeInFramesRemaining = fadeInTotalFrames
  }

  private func scheduleCompleteBatches(sampleRate: UInt32) {
    while accumulatedSamples.count / 2 >= renderBatchFrames {
      let sampleCount = renderBatchFrames * 2
      var samples = Array(accumulatedSamples.prefix(sampleCount))
      accumulatedSamples.removeFirst(sampleCount)
      guard
        let presentation = accumulatedPresentationNanoseconds,
        let roomPresentation = accumulatedRoomPresentationNanoseconds
      else { return }
      applyFadeIn(to: &samples, frameCount: renderBatchFrames)

      guard
        schedule(
          samples: samples,
          frameCount: renderBatchFrames,
          at: presentation,
          roomPresentationNanoseconds: roomPresentation
        )
      else {
        discardedPackets &+= UInt64(Self.packetsPerRenderBuffer)
        accumulatedSamples.removeAll(keepingCapacity: true)
        accumulatedPresentationNanoseconds = nil
        accumulatedRoomPresentationNanoseconds = nil
        return
      }
      accumulatedPresentationNanoseconds =
        presentation
        &+ durationNanoseconds(
          frames: renderBatchFrames,
          sampleRate: sampleRate
        )
      accumulatedRoomPresentationNanoseconds =
        roomPresentation
        &+ durationNanoseconds(frames: renderBatchFrames, sampleRate: sampleRate)
    }
  }

  private func schedule(
    samples: [Int16],
    frameCount: Int,
    at presentationNanoseconds: UInt64,
    roomPresentationNanoseconds: UInt64
  ) -> Bool {
    guard
      let sampleRate = configuredSampleRate,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(sampleRate),
        channels: 2
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      ),
      let channels = buffer.floatChannelData
    else { return false }

    let startPlan: PlaybackStartPlan?
    let isRecoveryAnchor: Bool
    switch playbackState.phase {
    case .priming(let anchor, let isRecovery):
      guard
        let plan = startPlanner.plan(
          presentationNanoseconds: anchor,
          outputLatencyNanoseconds: outputPresentationLatencyNanoseconds,
          nowNanoseconds: MonotonicTime.nowNanoseconds()
        )
      else {
        playbackState.didMissSelectedAnchor()
        return false
      }
      startPlan = plan
      isRecoveryAnchor = isRecovery
    case .playing:
      startPlan = nil
      isRecoveryAnchor = false
    case .awaitingAnchor, .recovering:
      return false
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    for frame in 0..<frameCount {
      channels[0][frame] = Float(samples[frame * 2]) / Float(Int16.max)
      channels[1][frame] = Float(samples[frame * 2 + 1]) / Float(Int16.max)
    }

    let generation = renderGeneration
    guard
      let playerSampleStart = nextScheduledPlayerSampleTime ?? startPlan?.playerSampleOrigin
    else { return false }
    if var streamTimeline {
      streamTimeline.observe(
        roomPresentationNanoseconds: roomPresentationNanoseconds,
        atPlayerSampleTime: playerSampleStart
      )
      self.streamTimeline = streamTimeline
    } else {
      streamTimeline = StreamTimeline(
        anchorRoomPresentationNanoseconds: roomPresentationNanoseconds,
        anchorPlayerSampleTime: playerSampleStart,
        sampleRate: sampleRate
      )
    }
    nextScheduledPlayerSampleTime = playerSampleStart + Int64(frameCount)
    nextScheduledBatchID &+= 1
    let batchID = nextScheduledBatchID
    scheduledFrames &+= UInt64(frameCount)
    scheduledBatches.append(
      ScheduledAudioBatch(
        id: batchID,
        samples: samples,
        frameCount: frameCount,
        roomPresentationNanoseconds: roomPresentationNanoseconds
      )
    )
    player.scheduleBuffer(
      buffer,
      at: nil,
      options: [],
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      guard let self else { return }
      queue.async { [self] in
        guard generation == renderGeneration else { return }
        scheduledBatches.removeAll { $0.id == batchID }
        scheduledFrames =
          scheduledFrames >= UInt64(frameCount)
          ? scheduledFrames - UInt64(frameCount) : 0
        if scheduledFrames == 0, isAcceptingAudio {
          transitionToRecovery()
        }
        publishStatisticsIfNeeded()
      }
    }

    if let startPlan {
      playbackState.didScheduleAnchor()
      if isRecoveryAnchor {
        resynchronizations &+= 1
        if pendingPhaseResynchronization {
          phaseResynchronizations &+= 1
          pendingPhaseResynchronization = false
        }
      }
      player.play(
        at: MonotonicTime.audioTime(nanoseconds: startPlan.renderStartNanoseconds)
      )
    }
    return true
  }

  private func transitionToRecovery() {
    guard playbackState.beginRecovery() else { return }
    rendererUnderruns &+= 1
    lastRecoveryReason = "Audio queue underrun"
    pendingPhaseResynchronization = false
    renderGeneration &+= 1
    scheduledFrames = 0
    scheduledBatches.removeAll(keepingCapacity: true)
    accumulatedSamples.removeAll(keepingCapacity: true)
    accumulatedPresentationNanoseconds = nil
    accumulatedRoomPresentationNanoseconds = nil
    fadeInFramesRemaining = 0
    fadeInTotalFrames = 0
    phaseController.reset()
    streamTimeline = nil
    nextScheduledPlayerSampleTime = nil
    lastPhaseObservationNanoseconds = 0
    varispeed.rate = 1
    player.volume = 0
    player.stop()
    player.volume = 1
    publishStatisticsIfNeeded(force: true)
  }

  private func recoverFromEngineConfigurationChange() {
    guard configuredSampleRate != nil else { return }

    let enteredRecovery = playbackState.didUnderrun()
    if enteredRecovery {
      rendererUnderruns &+= 1
      lastRecoveryReason = "Output device configuration changed"
    } else {
      playbackState.reset()
    }
    renderGeneration &+= 1
    stopEngine()
    jitterBuffer.reset()
    phaseController.reset()
    streamTimeline = nil
    nextScheduledPlayerSampleTime = nil
    configuredSampleRate = nil
    outputPresentationLatencyNanoseconds = 0
    renderBatchFrames = 0
    accumulatedSamples.removeAll(keepingCapacity: true)
    accumulatedPresentationNanoseconds = nil
    accumulatedRoomPresentationNanoseconds = nil
    scheduledFrames = 0
    scheduledBatches.removeAll(keepingCapacity: true)
    fadeInFramesRemaining = 0
    fadeInTotalFrames = 0
    varispeed.rate = 1
    lastPhaseObservationNanoseconds = 0
    publishStatisticsIfNeeded(force: true)
  }

  private func applyFadeIn(to samples: inout [Int16], frameCount: Int) {
    guard fadeInFramesRemaining > 0, fadeInTotalFrames > 0 else { return }
    for frame in 0..<frameCount where fadeInFramesRemaining > 0 {
      let completedFrames = fadeInTotalFrames - fadeInFramesRemaining + 1
      let gain = Double(completedFrames) / Double(fadeInTotalFrames)
      for channel in 0..<2 {
        let index = frame * 2 + channel
        samples[index] = Int16(clamping: Int((Double(samples[index]) * gain).rounded()))
      }
      fadeInFramesRemaining -= 1
    }
  }

  private func configureIfNeeded(sampleRate: UInt32, packetFrames: Int) throws {
    guard configuredSampleRate != sampleRate else {
      if !engine.isRunning {
        try engine.start()
        outputPresentationLatencyNanoseconds = UInt64(
          max(0, player.outputPresentationLatency) * 1_000_000_000
        )
      }
      return
    }

    stopEngine()
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(sampleRate),
        channels: 2
      )
    else { return }

    engine.connect(player, to: varispeed, format: format)
    engine.connect(varispeed, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    outputPresentationLatencyNanoseconds = UInt64(
      max(0, player.outputPresentationLatency) * 1_000_000_000
    )
    configuredSampleRate = sampleRate
    renderBatchFrames = packetFrames * Self.packetsPerRenderBuffer
    accumulatedSamples.reserveCapacity(renderBatchFrames * 4)
  }

  private func publishStatisticsIfNeeded(force: Bool = false) {
    let now = MonotonicTime.nowNanoseconds()
    guard force || now - lastStatisticsTime >= Self.statisticsIntervalNanoseconds else { return }
    observePlaybackPhaseIfNeeded(nowNanoseconds: now)
    lastStatisticsTime = now
    let jitter = jitterBuffer.statistics
    let recent = rollingEvents.observe(
      PlaybackEventCounters(
        missingPackets: jitter.missingPackets,
        latePackets: jitter.latePackets,
        reorderedPackets: jitter.reorderedPackets,
        rendererUnderruns: rendererUnderruns,
        resynchronizations: resynchronizations
      ),
      at: now
    )
    let sampleRate = configuredSampleRate.map(Double.init) ?? 0
    let bufferDepth = sampleRate > 0 ? Double(scheduledFrames) * 1_000 / sampleRate : 0
    onStatistics?(
      PlaybackHealth(
        missingPackets: jitter.missingPackets,
        latePackets: jitter.latePackets,
        reorderedPackets: jitter.reorderedPackets,
        duplicatePackets: jitter.duplicatePackets,
        rendererUnderruns: rendererUnderruns,
        resynchronizations: resynchronizations,
        discardedPackets: discardedPackets,
        bufferDepthMilliseconds: bufferDepth,
        playbackRatePartsPerMillion: (phaseController.playbackRate - 1) * 1_000_000,
        phaseErrorMilliseconds: phaseController.phaseErrorMilliseconds,
        outputLatencyMilliseconds: Double(outputPresentationLatencyNanoseconds) / 1_000_000,
        recentMissingPackets: recent.missingPackets,
        recentLatePackets: recent.latePackets,
        recentReorderedPackets: recent.reorderedPackets,
        recentRendererUnderruns: recent.rendererUnderruns,
        recentResynchronizations: recent.resynchronizations,
        phaseResynchronizations: phaseResynchronizations,
        lastRecoveryReason: lastRecoveryReason
      )
    )
  }

  private func stopOnQueue() {
    isAcceptingAudio = false
    publishStatisticsIfNeeded(force: true)
    renderGeneration &+= 1
    stopEngine()
    jitterBuffer.reset()
    rollingEvents.reset()
    phaseController.reset()
    streamTimeline = nil
    nextScheduledPlayerSampleTime = nil
    playbackState.reset()
    configuredSampleRate = nil
    renderBatchFrames = 0
    accumulatedSamples.removeAll(keepingCapacity: true)
    accumulatedPresentationNanoseconds = nil
    accumulatedRoomPresentationNanoseconds = nil
    scheduledFrames = 0
    scheduledBatches.removeAll(keepingCapacity: true)
    fadeInFramesRemaining = 0
    fadeInTotalFrames = 0
    rendererUnderruns = 0
    resynchronizations = 0
    phaseResynchronizations = 0
    pendingPhaseResynchronization = false
    lastRecoveryReason = nil
    discardedPackets = 0
    lastStatisticsTime = 0
    lastPhaseObservationNanoseconds = 0
    outputPresentationLatencyNanoseconds = 0
  }

  private func stopEngine() {
    player.stop()
    engine.stop()
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(varispeed)
    varispeed.rate = 1
  }

  private func observePlaybackPhaseIfNeeded(
    nowNanoseconds: UInt64 = MonotonicTime.nowNanoseconds()
  ) {
    guard
      playbackState.phase == .playing,
      nowNanoseconds >= lastPhaseObservationNanoseconds &+ 100_000_000,
      let phaseError = measuredPhaseErrorNanoseconds()
    else { return }
    lastPhaseObservationNanoseconds = nowNanoseconds

    switch phaseController.observe(
      phaseErrorNanoseconds: phaseError,
      at: nowNanoseconds
    ) {
    case .adjustRate(let rate):
      varispeed.rate = Float(rate)
    case .reanchor:
      performControlledPhaseReanchor(nowNanoseconds: nowNanoseconds)
    }
  }

  private func measuredPhaseErrorNanoseconds() -> Int64? {
    guard
      let streamTimeline,
      let renderTime = player.lastRenderTime,
      renderTime.isHostTimeValid,
      let playerTime = player.playerTime(forNodeTime: renderTime),
      playerTime.isSampleTimeValid,
      playerTime.sampleTime >= 0
    else { return nil }

    return streamTimeline.phaseErrorNanoseconds(
      renderHostNanoseconds: MonotonicTime.ticksToNanoseconds(renderTime.hostTime),
      playerSampleTime: playerTime.sampleTime,
      outputLatencyNanoseconds: outputPresentationLatencyNanoseconds,
      roomClockMapping: roomClockMapping
    )
  }

  /// Reuses audio that is already buffered for a near-future presentation time. This avoids the
  /// full safety-buffer silence that a blind stop-and-wait recovery would create.
  private func performControlledPhaseReanchor(nowNanoseconds: UInt64) {
    guard
      let sampleRate = configuredSampleRate,
      playbackState.beginRecovery()
    else { return }
    lastRecoveryReason = "Room phase discontinuity"

    let presentations = scheduledBatches.compactMap {
      roomClockMapping.localTime(forRoomTime: $0.roomPresentationNanoseconds)
    }
    guard
      let anchorIndex = reanchorPlanner.anchorIndex(
        in: presentations,
        nowNanoseconds: nowNanoseconds
      )
    else {
      // The queue is already too shallow to reuse safely; regular recovery will select the next
      // packet with enough lead.
      pendingPhaseResynchronization = true
      renderGeneration &+= 1
      scheduledFrames = 0
      scheduledBatches.removeAll(keepingCapacity: true)
      accumulatedSamples.removeAll(keepingCapacity: true)
      accumulatedPresentationNanoseconds = nil
      accumulatedRoomPresentationNanoseconds = nil
      phaseController.reset()
      streamTimeline = nil
      nextScheduledPlayerSampleTime = nil
      lastPhaseObservationNanoseconds = 0
      varispeed.rate = 1
      player.volume = 0
      player.stop()
      player.volume = 1
      publishStatisticsIfNeeded(force: true)
      return
    }
    let retainedBatches = Array(scheduledBatches[anchorIndex...])
    let anchor = retainedBatches[0]
    guard
      let anchorLocalPresentation = roomClockMapping.localTime(
        forRoomTime: anchor.roomPresentationNanoseconds)
    else { return }

    pendingPhaseResynchronization = true
    renderGeneration &+= 1
    scheduledFrames = 0
    scheduledBatches.removeAll(keepingCapacity: true)
    phaseController.reset()
    streamTimeline = nil
    nextScheduledPlayerSampleTime = nil
    lastPhaseObservationNanoseconds = 0
    varispeed.rate = 1
    player.volume = 0
    player.stop()
    player.volume = 1

    guard
      playbackState.considerAnchor(
        presentationNanoseconds: anchorLocalPresentation,
        nowNanoseconds: nowNanoseconds
      )
    else {
      accumulatedSamples.removeAll(keepingCapacity: true)
      accumulatedPresentationNanoseconds = nil
      accumulatedRoomPresentationNanoseconds = nil
      publishStatisticsIfNeeded(force: true)
      return
    }

    fadeInTotalFrames = max(1, Int(sampleRate) * Self.fadeInMilliseconds / 1_000)
    fadeInFramesRemaining = fadeInTotalFrames
    for batch in retainedBatches {
      var samples = batch.samples
      applyFadeIn(to: &samples, frameCount: batch.frameCount)
      guard
        let localPresentation = roomClockMapping.localTime(
          forRoomTime: batch.roomPresentationNanoseconds),
        schedule(
          samples: samples,
          frameCount: batch.frameCount,
          at: localPresentation,
          roomPresentationNanoseconds: batch.roomPresentationNanoseconds
        )
      else { break }
    }
    publishStatisticsIfNeeded(force: true)
  }
}

private struct ScheduledAudioBatch {
  let id: UInt64
  let samples: [Int16]
  let frameCount: Int
  let roomPresentationNanoseconds: UInt64
}

private func durationNanoseconds(frames: Int, sampleRate: UInt32) -> UInt64 {
  UInt64((Double(frames) * 1_000_000_000 / Double(sampleRate)).rounded())
}
