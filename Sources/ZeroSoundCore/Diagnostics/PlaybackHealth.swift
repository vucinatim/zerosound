import Foundation

public struct PlaybackHealth: Codable, Equatable, Hashable, Sendable {
  public let missingPackets: UInt64
  public let latePackets: UInt64
  public let reorderedPackets: UInt64
  public let duplicatePackets: UInt64
  public let rendererUnderruns: UInt64
  public let resynchronizations: UInt64
  public let discardedPackets: UInt64
  public let bufferDepthMilliseconds: Double
  public let playbackRatePartsPerMillion: Double
  public let phaseErrorMilliseconds: Double?
  public let outputLatencyMilliseconds: Double
  public let concealedAudioMilliseconds: Double
  public let recentConcealedAudioMilliseconds: Double
  public let recentMissingPackets: UInt64
  public let recentLatePackets: UInt64
  public let recentReorderedPackets: UInt64
  public let recentRendererUnderruns: UInt64
  public let recentResynchronizations: UInt64
  public let phaseResynchronizations: UInt64
  public let lastRecoveryReason: String?

  public init(
    missingPackets: UInt64 = 0,
    latePackets: UInt64 = 0,
    reorderedPackets: UInt64 = 0,
    duplicatePackets: UInt64 = 0,
    rendererUnderruns: UInt64 = 0,
    resynchronizations: UInt64 = 0,
    discardedPackets: UInt64 = 0,
    bufferDepthMilliseconds: Double = 0,
    playbackRatePartsPerMillion: Double = 0,
    phaseErrorMilliseconds: Double? = nil,
    outputLatencyMilliseconds: Double = 0,
    concealedAudioMilliseconds: Double = 0,
    recentConcealedAudioMilliseconds: Double = 0,
    recentMissingPackets: UInt64 = 0,
    recentLatePackets: UInt64 = 0,
    recentReorderedPackets: UInt64 = 0,
    recentRendererUnderruns: UInt64 = 0,
    recentResynchronizations: UInt64 = 0,
    phaseResynchronizations: UInt64 = 0,
    lastRecoveryReason: String? = nil
  ) {
    self.missingPackets = missingPackets
    self.latePackets = latePackets
    self.reorderedPackets = reorderedPackets
    self.duplicatePackets = duplicatePackets
    self.rendererUnderruns = rendererUnderruns
    self.resynchronizations = resynchronizations
    self.discardedPackets = discardedPackets
    self.bufferDepthMilliseconds = bufferDepthMilliseconds
    self.playbackRatePartsPerMillion = playbackRatePartsPerMillion
    self.phaseErrorMilliseconds = phaseErrorMilliseconds
    self.outputLatencyMilliseconds = outputLatencyMilliseconds
    self.concealedAudioMilliseconds = concealedAudioMilliseconds
    self.recentConcealedAudioMilliseconds = recentConcealedAudioMilliseconds
    self.recentMissingPackets = recentMissingPackets
    self.recentLatePackets = recentLatePackets
    self.recentReorderedPackets = recentReorderedPackets
    self.recentRendererUnderruns = recentRendererUnderruns
    self.recentResynchronizations = recentResynchronizations
    self.phaseResynchronizations = phaseResynchronizations
    self.lastRecoveryReason = lastRecoveryReason
  }

  private enum CodingKeys: String, CodingKey {
    case missingPackets
    case latePackets
    case reorderedPackets
    case duplicatePackets
    case rendererUnderruns
    case resynchronizations
    case discardedPackets
    case bufferDepthMilliseconds
    case playbackRatePartsPerMillion
    case phaseErrorMilliseconds
    case outputLatencyMilliseconds
    case concealedAudioMilliseconds
    case recentConcealedAudioMilliseconds
    case recentMissingPackets
    case recentLatePackets
    case recentReorderedPackets
    case recentRendererUnderruns
    case recentResynchronizations
    case phaseResynchronizations
    case lastRecoveryReason
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    missingPackets = try values.decodeIfPresent(UInt64.self, forKey: .missingPackets) ?? 0
    latePackets = try values.decodeIfPresent(UInt64.self, forKey: .latePackets) ?? 0
    reorderedPackets = try values.decodeIfPresent(UInt64.self, forKey: .reorderedPackets) ?? 0
    duplicatePackets = try values.decodeIfPresent(UInt64.self, forKey: .duplicatePackets) ?? 0
    rendererUnderruns = try values.decodeIfPresent(UInt64.self, forKey: .rendererUnderruns) ?? 0
    resynchronizations =
      try values.decodeIfPresent(UInt64.self, forKey: .resynchronizations) ?? 0
    discardedPackets = try values.decodeIfPresent(UInt64.self, forKey: .discardedPackets) ?? 0
    bufferDepthMilliseconds =
      try values.decodeIfPresent(Double.self, forKey: .bufferDepthMilliseconds) ?? 0
    playbackRatePartsPerMillion =
      try values.decodeIfPresent(Double.self, forKey: .playbackRatePartsPerMillion) ?? 0
    phaseErrorMilliseconds =
      try values.decodeIfPresent(Double.self, forKey: .phaseErrorMilliseconds)
    outputLatencyMilliseconds =
      try values.decodeIfPresent(Double.self, forKey: .outputLatencyMilliseconds) ?? 0
    concealedAudioMilliseconds =
      try values.decodeIfPresent(Double.self, forKey: .concealedAudioMilliseconds) ?? 0
    recentConcealedAudioMilliseconds =
      try values.decodeIfPresent(Double.self, forKey: .recentConcealedAudioMilliseconds) ?? 0
    recentMissingPackets =
      try values.decodeIfPresent(UInt64.self, forKey: .recentMissingPackets) ?? 0
    recentLatePackets =
      try values.decodeIfPresent(UInt64.self, forKey: .recentLatePackets) ?? 0
    recentReorderedPackets =
      try values.decodeIfPresent(UInt64.self, forKey: .recentReorderedPackets) ?? 0
    recentRendererUnderruns =
      try values.decodeIfPresent(UInt64.self, forKey: .recentRendererUnderruns) ?? 0
    recentResynchronizations =
      try values.decodeIfPresent(UInt64.self, forKey: .recentResynchronizations) ?? 0
    phaseResynchronizations =
      try values.decodeIfPresent(UInt64.self, forKey: .phaseResynchronizations) ?? 0
    lastRecoveryReason = try values.decodeIfPresent(String.self, forKey: .lastRecoveryReason)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(missingPackets, forKey: .missingPackets)
    try values.encode(latePackets, forKey: .latePackets)
    try values.encode(reorderedPackets, forKey: .reorderedPackets)
    try values.encode(duplicatePackets, forKey: .duplicatePackets)
    try values.encode(rendererUnderruns, forKey: .rendererUnderruns)
    try values.encode(resynchronizations, forKey: .resynchronizations)
    try values.encode(discardedPackets, forKey: .discardedPackets)
    try values.encode(bufferDepthMilliseconds, forKey: .bufferDepthMilliseconds)
    try values.encode(playbackRatePartsPerMillion, forKey: .playbackRatePartsPerMillion)
    try values.encodeIfPresent(phaseErrorMilliseconds, forKey: .phaseErrorMilliseconds)
    try values.encode(outputLatencyMilliseconds, forKey: .outputLatencyMilliseconds)
    try values.encode(concealedAudioMilliseconds, forKey: .concealedAudioMilliseconds)
    try values.encode(recentConcealedAudioMilliseconds, forKey: .recentConcealedAudioMilliseconds)
    try values.encode(recentMissingPackets, forKey: .recentMissingPackets)
    try values.encode(recentLatePackets, forKey: .recentLatePackets)
    try values.encode(recentReorderedPackets, forKey: .recentReorderedPackets)
    try values.encode(recentRendererUnderruns, forKey: .recentRendererUnderruns)
    try values.encode(recentResynchronizations, forKey: .recentResynchronizations)
    try values.encode(phaseResynchronizations, forKey: .phaseResynchronizations)
    try values.encodeIfPresent(lastRecoveryReason, forKey: .lastRecoveryReason)
  }
}
