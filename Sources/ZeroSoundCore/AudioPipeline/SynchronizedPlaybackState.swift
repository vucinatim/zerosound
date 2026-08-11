import Foundation

enum SynchronizedPlaybackPhase: Equatable, Sendable {
  case awaitingAnchor
  case priming(anchorNanoseconds: UInt64, isRecovery: Bool)
  case playing
  case recovering
}

struct SynchronizedPlaybackState: Sendable {
  private let initialLeadNanoseconds: UInt64
  private let recoveryLeadNanoseconds: UInt64

  private(set) var phase: SynchronizedPlaybackPhase = .awaitingAnchor

  init(
    initialLeadNanoseconds: UInt64 = 20_000_000,
    recoveryLeadNanoseconds: UInt64 = 100_000_000
  ) {
    self.initialLeadNanoseconds = initialLeadNanoseconds
    self.recoveryLeadNanoseconds = recoveryLeadNanoseconds
  }

  var selectedAnchorNanoseconds: UInt64? {
    guard case .priming(let anchor, _) = phase else { return nil }
    return anchor
  }

  var isPrimingRecovery: Bool {
    guard case .priming(_, let isRecovery) = phase else { return false }
    return isRecovery
  }

  mutating func considerAnchor(
    presentationNanoseconds: UInt64,
    nowNanoseconds: UInt64
  ) -> Bool {
    let requiredLead: UInt64
    let isRecovery: Bool
    switch phase {
    case .awaitingAnchor:
      requiredLead = initialLeadNanoseconds
      isRecovery = false
    case .recovering:
      requiredLead = recoveryLeadNanoseconds
      isRecovery = true
    case .priming, .playing:
      return false
    }

    guard presentationNanoseconds >= nowNanoseconds &+ requiredLead else { return false }
    phase = .priming(
      anchorNanoseconds: presentationNanoseconds,
      isRecovery: isRecovery
    )
    return true
  }

  mutating func didScheduleAnchor() {
    guard case .priming = phase else { return }
    phase = .playing
  }

  mutating func didMissSelectedAnchor() {
    guard case .priming(_, let isRecovery) = phase else { return }
    phase = isRecovery ? .recovering : .awaitingAnchor
  }

  mutating func didUnderrun() -> Bool {
    beginRecovery()
  }

  mutating func beginRecovery() -> Bool {
    guard phase == .playing else { return false }
    phase = .recovering
    return true
  }

  mutating func reset() {
    phase = .awaitingAnchor
  }
}
