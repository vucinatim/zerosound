import Foundation

enum JoinPhase: Equatable, Sendable {
  case idle
  case connectingControl
  case awaitingAudioOffer
  case registeringAudio
  case joined
  case closed
}

enum JoinTransition: Sendable {
  case begin
  case controlReady
  case audioOffered
  case accepted
  case close
}

enum JoinStateError: Error, Equatable {
  case invalidTransition(from: JoinPhase, transition: JoinTransition)
}

struct JoinStateMachine: Sendable {
  private(set) var phase: JoinPhase = .idle

  var isJoined: Bool { phase == .joined }

  mutating func apply(_ transition: JoinTransition) throws {
    let next: JoinPhase
    switch (phase, transition) {
    case (.idle, .begin), (.closed, .begin):
      next = .connectingControl
    case (.connectingControl, .controlReady):
      next = .awaitingAudioOffer
    case (.awaitingAudioOffer, .audioOffered), (.registeringAudio, .audioOffered):
      next = .registeringAudio
    case (.registeringAudio, .accepted):
      next = .joined
    case (_, .close):
      next = .closed
    default:
      throw JoinStateError.invalidTransition(from: phase, transition: transition)
    }
    phase = next
  }
}
