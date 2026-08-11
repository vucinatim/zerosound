import Foundation

extension RoomCommand {
  func isAuthorized(for sender: MemberID) -> Bool {
    switch self {
    case .join(let member): member.id == sender
    case .renameRoom(let memberID, _): memberID == sender
    case .leave(let memberID), .requestSource(let memberID), .releaseSource(let memberID):
      memberID == sender
    case .heartbeat(let memberID, _, _, _), .sourcePrimed(let memberID, _),
      .sourceLive(let memberID, _), .sourceStopped(let memberID, _),
      .sourceFailed(let memberID, _, _), .claimCoordinator(let memberID, _):
      memberID == sender
    }
  }
}
