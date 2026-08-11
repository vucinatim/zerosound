import Foundation
import Testing

@testable import ZeroSoundCore

@Test func clockSampleCalculatesOffsetAndNetworkRoundTrip() {
  let sample = ClockSample(
    clientSend: 1_000,
    coordinatorReceive: 1_160,
    coordinatorSend: 1_180,
    clientReceive: 1_100
  )

  #expect(sample.coordinatorOffsetNanoseconds == 120)
  #expect(sample.roundTripNanoseconds == 80)
}

@Test func estimatorBootstrapsFromLowestLatencySampleWithoutExposingAnUnstableClock() {
  var estimator = ClockEstimator()
  estimator.add(clockSample(localMidpoint: 1_000_000, offset: 300, roundTrip: 200))
  estimator.add(clockSample(localMidpoint: 2_000_000, offset: 125, roundTrip: 100))
  estimator.add(clockSample(localMidpoint: 3_000_000, offset: 500, roundTrip: 400))
  #expect(!estimator.isLocked)
  #expect(estimator.localTime(forCoordinatorTime: 5_000_000) == nil)

  estimator.add(clockSample(localMidpoint: 4_000_000, offset: 80, roundTrip: 90))

  #expect(estimator.isLocked)
  #expect(estimator.coordinatorOffsetNanoseconds == 80)
  #expect(estimator.bestRoundTripNanoseconds == 90)
  #expect(estimator.localTime(forCoordinatorTime: 5_000_080) == 5_000_000)
  #expect(estimator.coordinatorTime(forLocalTime: 5_000_000) == 5_000_080)
}

@Test func estimatorSlewsNewPhaseEvidenceInsteadOfJumpingTheRoomTimeline() throws {
  var estimator = ClockEstimator()
  for index in 0..<4 {
    estimator.add(
      clockSample(
        localMidpoint: 1_000_000_000 + UInt64(index) * 500_000_000,
        offset: 1_000_000,
        roundTrip: 4_000_000
      ))
  }
  let before = try #require(estimator.coordinatorOffsetNanoseconds)

  estimator.add(
    clockSample(
      localMidpoint: 3_000_000_000,
      offset: 11_000_000,
      roundTrip: 3_900_000
    ))
  let after = try #require(estimator.coordinatorOffsetNanoseconds)

  #expect(abs(after - before) <= 250_000)
}

@Test func estimatorLearnsClockSkewAndRejectsHighLatencyOutliers() throws {
  var estimator = ClockEstimator(capacity: 180)
  let origin: UInt64 = 10_000_000_000
  let offset = 5_000_000_000.0
  let expectedRate = 1.000_020

  for index in 0..<180 {
    let local = origin + UInt64(index) * 500_000_000
    let elapsed = Double(local - origin)
    let normalCoordinator = Double(local) + offset + elapsed * (expectedRate - 1)
    let isOutlier = index.isMultiple(of: 17)
    estimator.add(
      clockSample(
        localMidpoint: local,
        coordinatorMidpoint: UInt64(normalCoordinator.rounded())
          + (isOutlier ? 8_000_000 : 0),
        roundTrip: isOutlier ? 30_000_000 : 4_000_000 + UInt64(index % 3) * 200_000
      ))
  }

  #expect(abs(estimator.clockRatePartsPerMillion - 20) < 4)
  let futureLocal = origin + 100_000_000_000
  let mapped = try #require(estimator.coordinatorTime(forLocalTime: futureLocal))
  let expected = UInt64(
    (Double(futureLocal) + offset + 100_000_000_000 * (expectedRate - 1)).rounded()
  )
  #expect(abs(Int64(mapped) - Int64(expected)) < 1_500_000)
}

@Test func audioPacketRoundTrips() throws {
  let original = AudioPacket(
    sequence: 7,
    presentationNanoseconds: 8_000_000,
    sampleRate: 48_000,
    floatSamples: [-1, -0.5, 0, 0.5, 1, 0.25]
  )

  let encoded = original.encode()
  let decoded = try #require(AudioPacket.decode(encoded))

  #expect(decoded == original)
  #expect(encoded.count == AudioPacket.headerSize + original.samples.count * 2)
}

@Test func audioPacketRejectsMalformedPayload() {
  let original = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 2,
    sampleRate: 48_000,
    floatSamples: [0, 0]
  )
  var encoded = original.encode()
  encoded.removeLast()

  #expect(AudioPacket.decode(encoded) == nil)
}

@Test func productionAudioPacketStaysBelowTheConservativeDatagramBudget() {
  let packet = AudioPacket(
    sequence: 1,
    presentationNanoseconds: 1,
    sampleRate: 48_000,
    floatSamples: [Float](repeating: 0, count: SystemAudioStreamer.packetFrames * 2)
  )

  #expect(packet.encode().count == 1_008)
  #expect(packet.encode().count < 1_200)
}

@Test func controlFrameDecoderHandlesArbitraryTCPReadBoundaries() throws {
  let first = Data("first message".utf8)
  let second = Data("second message".utf8)
  let stream = try ControlFrameCodec.encode(first) + ControlFrameCodec.encode(second)
  var decoder = ControlFrameDecoder()
  var decoded: [Data] = []

  for byte in stream {
    decoded.append(contentsOf: try decoder.append(Data([byte])))
  }
  try decoder.finish()

  #expect(decoded == [first, second])
}

@Test func controlFrameDecoderRejectsInvalidAndTruncatedFrames() throws {
  var oversized = ControlFrameDecoder(maximumPayloadBytes: 8)
  #expect(throws: ControlFrameError.frameTooLarge(9)) {
    try oversized.append(Data([0, 0, 0, 9]))
  }

  var empty = ControlFrameDecoder()
  #expect(throws: ControlFrameError.emptyFrame) {
    try empty.append(Data([0, 0, 0, 0]))
  }

  var truncated = ControlFrameDecoder()
  _ = try truncated.append(Data([0, 0, 0, 4, 1, 2]))
  #expect(throws: ControlFrameError.truncatedFrame) {
    try truncated.finish()
  }
}

@Test func audioPlaneControlRoundTripsWithoutCollidingWithAudioPackets() throws {
  let registration = AudioPlaneControl.register(
    roomID: RoomID(),
    memberID: MemberID(),
    coordinatorTerm: 7,
    token: UUID()
  )
  let encoded = try AudioPlaneControlCodec.encode(registration)

  #expect(try AudioPlaneControlCodec.decode(encoded) == registration)
  #expect(AudioPacket.decode(encoded) == nil)
  #expect(try AudioPlaneControlCodec.decode(Data("unrelated".utf8)) == nil)
}

@Test func audioRegistrationLeaseIsSingleUseAndExpiresIndependently() {
  let token = UUID()
  var lease = AudioRegistrationLease(
    token: token,
    issuedAtNanoseconds: 1_000,
    lifetimeNanoseconds: 500
  )

  let wrongTokenAccepted = lease.consume(token: UUID(), at: 1_100)
  let firstUseAccepted = lease.consume(token: token, at: 1_499)
  let replayAccepted = lease.consume(token: token, at: 1_499)
  #expect(!wrongTokenAccepted)
  #expect(firstUseAccepted)
  #expect(!replayAccepted)

  var expired = AudioRegistrationLease(
    token: token,
    issuedAtNanoseconds: 1_000,
    lifetimeNanoseconds: 500
  )
  let expiredTokenAccepted = expired.consume(token: token, at: 1_500)
  #expect(!expiredTokenAccepted)
}

@Test func realTimeSendQueueIsBoundedAndKeepsOnlyTheNewestPendingPacket() {
  var queue = LatestValueSendQueue<Int>()

  #expect(queue.enqueue(1) == 1)
  #expect(queue.enqueue(2) == nil)
  #expect(queue.enqueue(3) == nil)
  #expect(queue.droppedValues == 1)
  #expect(queue.didComplete() == 3)
  #expect(queue.didComplete() == nil)
  #expect(queue.enqueue(4) == 4)
}

@Test func jitterBufferReordersPacketsWithoutBreakingContinuity() {
  var buffer = PacketJitterBuffer(startupHoldNanoseconds: 0)
  let start: UInt64 = 1_000_000_000

  let first = buffer.insert(timedPacket(sequence: 10, presentation: start), nowNanoseconds: 0)
  let third = buffer.insert(
    timedPacket(sequence: 12, presentation: start + 10_000_000),
    nowNanoseconds: 1
  )
  let reordered = buffer.insert(
    timedPacket(sequence: 11, presentation: start + 5_000_000),
    nowNanoseconds: 2
  )

  #expect(first.map(\.sequence) == [10])
  #expect(third.isEmpty)
  #expect(reordered.map(\.sequence) == [11, 12])
  #expect(buffer.statistics.reorderedPackets == 1)
  #expect(buffer.statistics.missingPackets == 0)
}

@Test func jitterBufferConcealsMissingPacketBeforePlaybackDeadline() {
  var buffer = PacketJitterBuffer(startupHoldNanoseconds: 0)
  let start: UInt64 = 1_000_000_000

  _ = buffer.insert(timedPacket(sequence: 20, presentation: start), nowNanoseconds: 0)
  let early = buffer.insert(
    timedPacket(sequence: 22, presentation: start + 10_000_000, sample: 12_000),
    nowNanoseconds: start - 100_000_000
  )
  let recovered = buffer.drain(
    nowNanoseconds: start + 5_000_000 - PacketJitterBuffer.schedulingLeadNanoseconds
  )

  #expect(early.isEmpty)
  #expect(recovered.map(\.sequence) == [21, 22])
  #expect(recovered[0].isConcealed)
  #expect(!recovered[1].isConcealed)
  #expect(buffer.statistics.missingPackets == 1)
}

@Test func jitterBufferConcealsLossAfterShortReorderWindowWithoutDrainingSafetyBuffer() {
  var buffer = PacketJitterBuffer(
    startupHoldNanoseconds: 0,
    reorderHoldNanoseconds: 20_000_000
  )
  let presentation: UInt64 = 1_000_000_000

  _ = buffer.insert(timedPacket(sequence: 20, presentation: presentation), nowNanoseconds: 0)
  let gapDetected = buffer.insert(
    timedPacket(sequence: 22, presentation: presentation + 10_000_000),
    nowNanoseconds: 100_000_000
  )
  let stillWaiting = buffer.drain(nowNanoseconds: 119_999_999)
  let recovered = buffer.drain(nowNanoseconds: 120_000_000)

  #expect(gapDetected.isEmpty)
  #expect(stillWaiting.isEmpty)
  #expect(recovered.map(\.sequence) == [21, 22])
  #expect(buffer.statistics.missingPackets == 1)
  #expect(presentation - 120_000_000 == 880_000_000)
}

@Test func jitterBufferAcceptsReorderedPacketBeforeGapDeadline() {
  var buffer = PacketJitterBuffer(
    startupHoldNanoseconds: 0,
    reorderHoldNanoseconds: 20_000_000
  )
  let presentation: UInt64 = 1_000_000_000

  _ = buffer.insert(timedPacket(sequence: 30, presentation: presentation), nowNanoseconds: 0)
  _ = buffer.insert(
    timedPacket(sequence: 32, presentation: presentation + 10_000_000),
    nowNanoseconds: 100_000_000
  )
  let recovered = buffer.insert(
    timedPacket(sequence: 31, presentation: presentation + 5_000_000),
    nowNanoseconds: 115_000_000
  )

  #expect(recovered.map(\.sequence) == [31, 32])
  #expect(recovered.allSatisfy { !$0.isConcealed })
  #expect(buffer.statistics.missingPackets == 0)
  #expect(buffer.statistics.reorderedPackets == 1)
}

@Test func jitterBufferConcealsBurstLossAsOneContinuousTimeline() {
  var buffer = PacketJitterBuffer(
    startupHoldNanoseconds: 0,
    reorderHoldNanoseconds: 20_000_000
  )
  let presentation: UInt64 = 1_000_000_000

  _ = buffer.insert(timedPacket(sequence: 40, presentation: presentation), nowNanoseconds: 0)
  _ = buffer.insert(
    timedPacket(sequence: 44, presentation: presentation + 20_000_000),
    nowNanoseconds: 100_000_000
  )
  let recovered = buffer.drain(nowNanoseconds: 120_000_000)

  #expect(recovered.map(\.sequence) == [41, 42, 43, 44])
  #expect(recovered.map(\.isConcealed) == [true, true, true, false])
  #expect(buffer.statistics.missingPackets == 3)
  #expect(
    zip(recovered, recovered.dropFirst()).allSatisfy {
      $1.localPresentationNanoseconds - $0.localPresentationNanoseconds == 5_000_000
    })
}

@Test func jitterBufferRejectsPacketsThatAlreadyMissedTheirTimeline() {
  var buffer = PacketJitterBuffer(startupHoldNanoseconds: 0)
  _ = buffer.insert(timedPacket(sequence: 30, presentation: 1_000_000_000), nowNanoseconds: 0)
  let late = buffer.insert(
    timedPacket(sequence: 30, presentation: 1_000_000_000),
    nowNanoseconds: 1
  )

  #expect(late.isEmpty)
  #expect(buffer.statistics.latePackets == 1)
}

@Test func jitterBufferUsesStartupWindowToRecoverAnEarlierFirstPacket() {
  var buffer = PacketJitterBuffer(startupHoldNanoseconds: 15_000_000)
  let start: UInt64 = 1_000_000_000

  let second = buffer.insert(
    timedPacket(sequence: 41, presentation: start + 5_000_000),
    nowNanoseconds: 0
  )
  let first = buffer.insert(
    timedPacket(sequence: 40, presentation: start),
    nowNanoseconds: 5_000_000
  )
  let third = buffer.insert(
    timedPacket(sequence: 42, presentation: start + 10_000_000),
    nowNanoseconds: 15_000_000
  )

  #expect(second.isEmpty)
  #expect(first.isEmpty)
  #expect(third.map(\.sequence) == [40, 41, 42])
  #expect(buffer.statistics.latePackets == 0)
  #expect(buffer.statistics.reorderedPackets == 1)
}

@Test func phaseControllerCorrectsMeasuredLateAndEarlyPlayback() {
  var lateController = PlaybackPhaseController(phaseFilterFactor: 1, rateFilterFactor: 1)
  let late = lateController.observe(phaseErrorNanoseconds: 8_000_000, at: 1_000_000_000)
  guard case .adjustRate(let lateRate) = late else {
    Issue.record("A small phase error must use continuous rate correction")
    return
  }
  #expect(lateRate > 1)

  var earlyController = PlaybackPhaseController(phaseFilterFactor: 1, rateFilterFactor: 1)
  let early = earlyController.observe(phaseErrorNanoseconds: -8_000_000, at: 1_000_000_000)
  guard case .adjustRate(let earlyRate) = early else {
    Issue.record("A small phase error must use continuous rate correction")
    return
  }
  #expect(earlyRate < 1)
}

@Test func streamTimelineMeasuresHardwarePhaseAgainstIntendedPresentation() throws {
  let timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 0,
    sampleRate: 48_000
  )
  let synchronized = try #require(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 1_497_500_000,
      playerSampleTime: 24_000,
      outputLatencyNanoseconds: 2_500_000,
      roomClockMapping: .identity
    )
  )
  #expect(synchronized == 0)

  let late = try #require(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 1_505_500_000,
      playerSampleTime: 24_000,
      outputLatencyNanoseconds: 2_500_000,
      roomClockMapping: .identity
    )
  )
  #expect(late == 8_000_000)
}

@Test func playbackStartPlanAlignsPlayerSampleZeroWithHardwarePresentation() throws {
  let planner = PlaybackStartPlanner(minimumSchedulingLeadNanoseconds: 5_000_000)
  let plan = try #require(
    planner.plan(
      presentationNanoseconds: 1_300_000_000,
      outputLatencyNanoseconds: 2_500_000,
      nowNanoseconds: 1_000_000_000
    )
  )

  #expect(plan.presentationNanoseconds == 1_300_000_000)
  #expect(plan.renderStartNanoseconds == 1_297_500_000)
  #expect(plan.playerSampleOrigin == 0)

  let timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: plan.presentationNanoseconds,
    anchorPlayerSampleTime: plan.playerSampleOrigin,
    sampleRate: 48_000
  )
  let synchronized = try #require(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 1_797_500_000,
      playerSampleTime: 24_000,
      outputLatencyNanoseconds: 2_500_000,
      roomClockMapping: .identity
    )
  )
  #expect(synchronized == 0)
}

@Test func playbackStartPlanRejectsAnAnchorWithoutHardwareSchedulingLead() {
  let planner = PlaybackStartPlanner(minimumSchedulingLeadNanoseconds: 5_000_000)
  let plan = planner.plan(
    presentationNanoseconds: 1_007_000_000,
    outputLatencyNanoseconds: 2_500_000,
    nowNanoseconds: 1_000_000_000
  )

  #expect(plan == nil)
}

@Test func streamTimelineUsesItsExplicitPlayerSampleOrigin() throws {
  // A player started 70 ms before its content anchor reports 3,360 pre-roll samples at 48 kHz.
  // Treating those as content frames recreates the production -70 ms false phase error.
  let timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 3_360,
    sampleRate: 48_000
  )
  let synchronized = try #require(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 1_497_500_000,
      playerSampleTime: 27_360,
      outputLatencyNanoseconds: 2_500_000,
      roomClockMapping: .identity
    )
  )

  #expect(synchronized == 0)
  #expect(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 999_000_000,
      playerSampleTime: 3_359,
      outputLatencyNanoseconds: 2_500_000,
      roomClockMapping: .identity
    ) == nil
  )
}

@Test func streamTimelineReconcilesAnActivePlayheadWithUpdatedRoomClock() throws {
  let timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 0,
    sampleRate: 48_000
  )
  let correctedMapping = RoomClockMapping(
    referenceLocalNanoseconds: 1_000_000_000,
    referenceRoomNanoseconds: 1_020_000_000,
    roomRate: 1
  )

  let phaseError = try #require(
    timeline.phaseErrorNanoseconds(
      renderHostNanoseconds: 1_500_000_000,
      playerSampleTime: 24_000,
      outputLatencyNanoseconds: 0,
      roomClockMapping: correctedMapping
    )
  )

  #expect(phaseError == 20_000_000)
}

@Test func streamTimelineLearnsSourceClockRateWithoutLosingPhase() throws {
  var timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 0,
    sampleRate: 48_000
  )
  let sourceRate = 1 + 40.0 / 1_000_000

  for batch in 1...(12 * 50) {
    let playerSample = Int64(batch * 960)
    let elapsedSeconds = Double(batch) / 50
    let roomTime = UInt64(
      (1_000_000_000 + elapsedSeconds * 1_000_000_000 * sourceRate).rounded())
    timeline.observe(
      roomPresentationNanoseconds: roomTime,
      atPlayerSampleTime: playerSample
    )
  }

  let predicted = try #require(timeline.roomTime(forPlayerSampleTime: 13 * 48_000))
  let expected = UInt64((1_000_000_000 + 13 * 1_000_000_000 * sourceRate).rounded())
  #expect(abs(Int64(predicted) - Int64(expected)) < 100_000)
}

@Test func continuousPlayoutConvergesThroughClockSkewLossAndMappingCorrection() throws {
  let sampleRate: UInt32 = 48_000
  let framesPerStep: Int64 = 960
  let stepNanoseconds: UInt64 = 20_000_000
  let sourceRate = 1 + 35.0 / 1_000_000
  let hardwareRate = 1 - 25.0 / 1_000_000
  var roomMapping = RoomClockMapping(
    referenceLocalNanoseconds: 1_000_000_000,
    referenceRoomNanoseconds: 1_000_000_000,
    roomRate: 1 + 18.0 / 1_000_000
  )
  var timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 0,
    sampleRate: sampleRate
  )
  var controller = PlaybackPhaseController(
    phaseFilterFactor: 0.25,
    rateFilterFactor: 0.2
  )
  var localTime: UInt64 = 1_008_000_000
  var renderedPlayerSamples = 0.0

  for step in 1...(60 * 50) {
    let scheduledSample = Int64(step) * framesPerStep
    let elapsedStreamSeconds = Double(scheduledSample) / Double(sampleRate)
    let packetRoomTime = UInt64(
      (1_000_000_000 + elapsedStreamSeconds * 1_000_000_000 * sourceRate).rounded())
    let isBurstLoss = (1_200...1_204).contains(step)
    if !isBurstLoss && step % 97 != 0 {
      timeline.observe(
        roomPresentationNanoseconds: packetRoomTime,
        atPlayerSampleTime: scheduledSample
      )
    }

    localTime &+= stepNanoseconds
    renderedPlayerSamples +=
      Double(framesPerStep) * hardwareRate * controller.playbackRate
    let playerSample = Int64(renderedPlayerSamples.rounded())
    let phaseError = try #require(
      timeline.phaseErrorNanoseconds(
        renderHostNanoseconds: localTime,
        playerSampleTime: playerSample,
        outputLatencyNanoseconds: 0,
        roomClockMapping: roomMapping
      ))
    _ = controller.observe(phaseErrorNanoseconds: phaseError, at: localTime)

    if step == 1_500 {
      roomMapping = RoomClockMapping(
        referenceLocalNanoseconds: localTime,
        referenceRoomNanoseconds: Double(
          try #require(roomMapping.roomTime(forLocalTime: localTime))) + 2_000_000,
        roomRate: roomMapping.roomRate
      )
    }
  }

  let finalPhase = try #require(controller.phaseErrorMilliseconds)
  #expect(abs(finalPhase) < 2)
}

@Test func deterministicFaultSeedsKeepContinuousPlayoutBounded() throws {
  let seeds: [UInt64] = [0x5EED_0001, 0x5EED_0002, 0x5EED_0003, 0x5EED_0004, 0x5EED_0005]

  for seed in seeds {
    let finalPhase = try simulatedFinalPhaseMilliseconds(seed: seed)
    #expect(
      abs(finalPhase) < 3,
      "Seed \(String(seed, radix: 16)) finished at \(finalPhase) ms"
    )
  }
}

@Test(.timeLimit(.minutes(1)))
func fourHourVirtualSoakKeepsIndependentClocksInRoomPhase() throws {
  let seeds: [UInt64] = [0x50A4_0001, 0x50A4_0002]

  for seed in seeds {
    let finalPhase = try simulatedFinalPhaseMilliseconds(
      seed: seed,
      durationSeconds: 4 * 60 * 60,
      correctionMagnitudeNanoseconds: 250_000
    )
    #expect(
      abs(finalPhase) < 3,
      "Four-hour seed \(String(seed, radix: 16)) finished at \(finalPhase) ms"
    )
  }
}

@Test func reanchorPlannerReusesOnlySafelySchedulableFutureAudio() {
  let planner = PlaybackReanchorPlanner(minimumLeadNanoseconds: 120_000_000)
  let presentations: [UInt64] = [
    1_080_000_000,
    1_100_000_000,
    1_120_000_000,
    1_140_000_000,
  ]

  #expect(planner.anchorIndex(in: presentations, nowNanoseconds: 1_000_000_000) == 2)
  #expect(planner.anchorIndex(in: presentations, nowNanoseconds: 1_030_000_000) == nil)
}

@Test func phaseControllerReanchorsOnlyAfterPersistentLargeError() {
  var controller = PlaybackPhaseController(
    phaseFilterFactor: 1,
    rateFilterFactor: 1,
    reanchorThresholdMilliseconds: 40,
    reanchorPersistenceNanoseconds: 1_000_000_000
  )
  #expect(
    controller.observe(phaseErrorNanoseconds: 50_000_000, at: 1_000_000_000)
      != .reanchor)
  #expect(
    controller.observe(phaseErrorNanoseconds: 50_000_000, at: 1_900_000_000)
      != .reanchor)
  #expect(
    controller.observe(phaseErrorNanoseconds: 50_000_000, at: 2_000_000_000)
      == .reanchor)
}

@Test func rollingPlaybackEventsExpireInsteadOfMakingHealthPermanentlyDegraded() {
  var events = RollingPlaybackEvents(windowNanoseconds: 10_000_000_000)
  let initial = events.observe(
    PlaybackEventCounters(missingPackets: 3, reorderedPackets: 1),
    at: 1_000_000_000
  )
  #expect(initial.missingPackets == 3)
  #expect(initial.reorderedPackets == 1)

  let expired = events.observe(
    PlaybackEventCounters(missingPackets: 3, reorderedPackets: 1),
    at: 11_000_000_001
  )
  #expect(expired == PlaybackEventCounters())
}

@Test func playbackStateRequiresAFutureInitialAnchor() {
  var state = SynchronizedPlaybackState(
    initialLeadNanoseconds: 20_000_000,
    recoveryLeadNanoseconds: 100_000_000
  )

  let rejected = state.considerAnchor(
    presentationNanoseconds: 1_010_000_000,
    nowNanoseconds: 1_000_000_000
  )
  #expect(!rejected)
  #expect(state.phase == .awaitingAnchor)
  let accepted = state.considerAnchor(
    presentationNanoseconds: 1_020_000_000,
    nowNanoseconds: 1_000_000_000
  )
  #expect(accepted)
  #expect(state.selectedAnchorNanoseconds == 1_020_000_000)

  state.didScheduleAnchor()
  #expect(state.phase == .playing)
}

@Test func playbackStateInvalidatesAnchorAndUsesRecoveryLeadAfterUnderrun() {
  var state = SynchronizedPlaybackState(
    initialLeadNanoseconds: 20_000_000,
    recoveryLeadNanoseconds: 100_000_000
  )
  let initialAnchor = state.considerAnchor(
    presentationNanoseconds: 1_200_000_000,
    nowNanoseconds: 1_000_000_000
  )
  #expect(initialAnchor)
  state.didScheduleAnchor()

  let detectedUnderrun = state.didUnderrun()
  #expect(detectedUnderrun)
  #expect(state.phase == .recovering)
  let rejectedRecovery = state.considerAnchor(
    presentationNanoseconds: 2_099_000_000,
    nowNanoseconds: 2_000_000_000
  )
  #expect(!rejectedRecovery)
  let acceptedRecovery = state.considerAnchor(
    presentationNanoseconds: 2_100_000_000,
    nowNanoseconds: 2_000_000_000
  )
  #expect(acceptedRecovery)
  #expect(state.isPrimingRecovery)

  state.didScheduleAnchor()
  #expect(state.phase == .playing)
}

@Test func playbackHealthDecodesReportsFromEarlierAppVersionsWithoutInventingRecentFailures() throws
{
  let data = Data(
    #"{"missingPackets":1,"latePackets":0,"reorderedPackets":2,"duplicatePackets":0,"rendererUnderruns":1,"bufferDepthMilliseconds":280,"playbackRatePartsPerMillion":12}"#
      .utf8
  )

  let health = try JSONDecoder().decode(PlaybackHealth.self, from: data)
  #expect(health.rendererUnderruns == 1)
  #expect(health.resynchronizations == 0)
  #expect(health.discardedPackets == 0)
  #expect(health.outputLatencyMilliseconds == 0)
  #expect(health.lastRecoveryReason == nil)
  #expect(!health.requiresAttention)
}

@Test func transportDiagnosticsDecodeBeforeSendDropsFromOlderReports() throws {
  let data = Data(
    #"{"control":"ready","audio":"ready","joinStage":"Ready"}"#.utf8
  )

  let diagnostics = try JSONDecoder().decode(TransportDiagnostics.self, from: data)
  #expect(diagnostics.audioDatagramsDroppedBeforeSend == 0)
}

@Test func playbackHealthClearsAttentionAfterAutomaticResynchronization() {
  let recovering = PlaybackHealth(
    rendererUnderruns: 1,
    recentRendererUnderruns: 1
  )
  let recovered = PlaybackHealth(
    rendererUnderruns: 1,
    resynchronizations: 1,
    recentRendererUnderruns: 1,
    recentResynchronizations: 1
  )

  #expect(recovering.requiresAttention)
  #expect(!recovered.requiresAttention)
}

@Test func playbackStateReturnsToRecoveryWhenSelectedAnchorExpires() {
  var state = SynchronizedPlaybackState(
    initialLeadNanoseconds: 20_000_000,
    recoveryLeadNanoseconds: 100_000_000
  )
  _ = state.considerAnchor(
    presentationNanoseconds: 1_200_000_000,
    nowNanoseconds: 1_000_000_000
  )
  state.didScheduleAnchor()
  _ = state.didUnderrun()
  _ = state.considerAnchor(
    presentationNanoseconds: 2_200_000_000,
    nowNanoseconds: 2_000_000_000
  )

  state.didMissSelectedAnchor()
  #expect(state.phase == .recovering)
}

@Test @MainActor func controllerPersistsIdentityAndUsesFriendlyDeviceName() throws {
  let suiteName = "ZeroSoundTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let first = ZeroSoundController(deviceName: "Office Mac.local", defaults: defaults)
  #expect(first.deviceName == "Office Mac")

  let restored = ZeroSoundController(deviceName: "Second Mac", defaults: defaults)
  #expect(restored.localMemberID == first.localMemberID)
}

private func timedPacket(
  sequence: UInt32,
  presentation: UInt64,
  sample: Float = 0.25
) -> TimedAudioPacket {
  TimedAudioPacket(
    packet: AudioPacket(
      sequence: sequence,
      presentationNanoseconds: presentation,
      sampleRate: 48_000,
      floatSamples: [Float](repeating: sample, count: 240 * 2)
    ),
    localPresentationNanoseconds: presentation
  )
}

private func clockSample(
  localMidpoint: UInt64,
  offset: Int64,
  roundTrip: UInt64
) -> ClockSample {
  let coordinatorMidpoint =
    offset >= 0
    ? localMidpoint + UInt64(offset)
    : localMidpoint - UInt64(offset.magnitude)
  return clockSample(
    localMidpoint: localMidpoint,
    coordinatorMidpoint: coordinatorMidpoint,
    roundTrip: roundTrip
  )
}

private func clockSample(
  localMidpoint: UInt64,
  coordinatorMidpoint: UInt64,
  roundTrip: UInt64
) -> ClockSample {
  let halfRoundTrip = roundTrip / 2
  return ClockSample(
    clientSend: localMidpoint - halfRoundTrip,
    coordinatorReceive: coordinatorMidpoint,
    coordinatorSend: coordinatorMidpoint,
    clientReceive: localMidpoint + (roundTrip - halfRoundTrip)
  )
}

private func simulatedFinalPhaseMilliseconds(
  seed: UInt64,
  durationSeconds: Int = 90,
  correctionMagnitudeNanoseconds: Double = 2_000_000
) throws -> Double {
  let sampleRate: UInt32 = 48_000
  let framesPerStep: Int64 = 960
  let stepNanoseconds: UInt64 = 20_000_000
  var random = DeterministicRandom(seed: seed)
  let sourceRate = 1 + random.signedUnit() * 60 / 1_000_000
  let hardwareRate = 1 + random.signedUnit() * 60 / 1_000_000
  let roomRate = 1 + random.signedUnit() * 40 / 1_000_000
  var roomMapping = RoomClockMapping(
    referenceLocalNanoseconds: 1_000_000_000,
    referenceRoomNanoseconds: 1_000_000_000,
    roomRate: roomRate
  )
  var timeline = StreamTimeline(
    anchorRoomPresentationNanoseconds: 1_000_000_000,
    anchorPlayerSampleTime: 0,
    sampleRate: sampleRate
  )
  var controller = PlaybackPhaseController(
    phaseFilterFactor: 0.25,
    rateFilterFactor: 0.2
  )
  var localTime: UInt64 = 1_008_000_000
  var renderedPlayerSamples = 0.0
  var burstLossRemaining = 0

  let totalSteps = durationSeconds * 50
  for step in 1...totalSteps {
    let scheduledSample = Int64(step) * framesPerStep
    let elapsedStreamSeconds = Double(scheduledSample) / Double(sampleRate)
    let packetRoomTime = UInt64(
      (1_000_000_000 + elapsedStreamSeconds * 1_000_000_000 * sourceRate).rounded())

    let isLost: Bool
    if burstLossRemaining > 0 {
      burstLossRemaining -= 1
      isLost = true
    } else if random.unit() < 0.006 {
      burstLossRemaining = 1 + Int(random.next() % 6)
      isLost = true
    } else {
      isLost = random.unit() < 0.012
    }
    if !isLost {
      timeline.observe(
        roomPresentationNanoseconds: packetRoomTime,
        atPlayerSampleTime: scheduledSample
      )
    }

    localTime &+= stepNanoseconds
    renderedPlayerSamples += Double(framesPerStep) * hardwareRate * controller.playbackRate
    let phaseError = try #require(
      timeline.phaseErrorNanoseconds(
        renderHostNanoseconds: localTime,
        playerSampleTime: Int64(renderedPlayerSamples.rounded()),
        outputLatencyNanoseconds: 0,
        roomClockMapping: roomMapping
      ))
    _ = controller.observe(phaseErrorNanoseconds: phaseError, at: localTime)

    if step < totalSteps, step.isMultiple(of: 30 * 50) {
      let mappedRoomTime = try #require(roomMapping.roomTime(forLocalTime: localTime))
      let correction = Int64(
        (random.signedUnit() * correctionMagnitudeNanoseconds).rounded())
      roomMapping = RoomClockMapping(
        referenceLocalNanoseconds: localTime,
        referenceRoomNanoseconds: Double(Int64(mappedRoomTime) + correction),
        roomRate: roomRate
      )
    }
  }

  return try #require(controller.phaseErrorMilliseconds)
}

private struct DeterministicRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }

  mutating func unit() -> Double {
    Double(next() >> 11) / Double(UInt64(1) << 53)
  }

  mutating func signedUnit() -> Double {
    unit() * 2 - 1
  }
}
