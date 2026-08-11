import Foundation

/// An immutable affine conversion between a member's monotonic clock and coordinator room time.
///
/// Passing snapshots across subsystem queues keeps clock estimation and audio rendering independent:
/// the network connection owns estimation, while the renderer can continuously evaluate its active
/// playhead against the latest published room clock without synchronously calling back into transport.
public struct RoomClockMapping: Equatable, Sendable {
  public let referenceLocalNanoseconds: UInt64
  public let referenceRoomNanoseconds: Double
  public let roomRate: Double

  public init(
    referenceLocalNanoseconds: UInt64,
    referenceRoomNanoseconds: Double,
    roomRate: Double
  ) {
    self.referenceLocalNanoseconds = referenceLocalNanoseconds
    self.referenceRoomNanoseconds = referenceRoomNanoseconds
    self.roomRate = roomRate
  }

  public static let identity = RoomClockMapping(
    referenceLocalNanoseconds: 0,
    referenceRoomNanoseconds: 0,
    roomRate: 1
  )

  public func localTime(forRoomTime roomTime: UInt64) -> UInt64? {
    guard roomRate.isFinite, roomRate > 0, referenceRoomNanoseconds.isFinite else { return nil }
    let roomDelta = Double(roomTime) - referenceRoomNanoseconds
    return clampedMappingTime(Double(referenceLocalNanoseconds) + roomDelta / roomRate)
  }

  public func roomTime(forLocalTime localTime: UInt64) -> UInt64? {
    guard roomRate.isFinite, roomRate > 0, referenceRoomNanoseconds.isFinite else { return nil }
    let localDelta = signedMappingDifference(localTime, referenceLocalNanoseconds)
    return clampedMappingTime(referenceRoomNanoseconds + localDelta * roomRate)
  }
}

private func signedMappingDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
  lhs >= rhs ? Double(lhs - rhs) : -Double(rhs - lhs)
}

private func clampedMappingTime(_ value: Double) -> UInt64? {
  guard value.isFinite, value >= 0, value <= Double(UInt64.max) else { return nil }
  return UInt64(value.rounded())
}
