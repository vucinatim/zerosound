import Foundation
@preconcurrency import Network

public struct DiscoveredRoom: Identifiable, Hashable, @unchecked Sendable {
  public let descriptor: RoomDescriptor
  let endpoint: NWEndpoint
  let audioPort: NWEndpoint.Port

  public var id: RoomID { descriptor.id }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.descriptor == rhs.descriptor
      && lhs.endpoint == rhs.endpoint
      && lhs.audioPort == rhs.audioPort
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(descriptor)
    hasher.combine(endpoint)
    hasher.combine(audioPort.rawValue)
  }
}

enum RoomAdvertisement {
  static func service(
    for snapshot: RoomSnapshot,
    audioPort: NWEndpoint.Port
  ) -> NWListener.Service {
    let descriptor = RoomDescriptor(snapshot: snapshot)
    let record = NWTXTRecord([
      "rid": descriptor.id.rawValue.uuidString,
      "name": descriptor.name,
      "count": String(descriptor.memberCount),
      "source": descriptor.sourceName ?? "",
      "cid": descriptor.coordinatorID.rawValue.uuidString,
      "term": String(descriptor.coordinatorTerm),
      "cv": String(descriptor.controlProtocolVersion),
      "av": String(ZeroSoundProtocol.audioVersion),
      "aport": String(audioPort.rawValue),
    ])
    return NWListener.Service(
      name: String(descriptor.name.prefix(42)),
      type: ZeroSoundProtocol.serviceType,
      txtRecord: record
    )
  }

  static func parse(_ record: NWTXTRecord) -> (RoomDescriptor, NWEndpoint.Port)? {
    let values = record.dictionary
    guard
      let roomText = values["rid"], let roomUUID = UUID(uuidString: roomText),
      let coordinatorText = values["cid"], let coordinatorUUID = UUID(uuidString: coordinatorText),
      let countText = values["count"], let count = Int(countText),
      let termText = values["term"], let term = UInt64(termText),
      let versionText = values["cv"], let version = UInt16(versionText),
      let audioPortText = values["aport"], let audioPortValue = UInt16(audioPortText),
      let audioPort = NWEndpoint.Port(rawValue: audioPortValue),
      let name = values["name"]
    else { return nil }
    let source = values["source"].flatMap { $0.isEmpty ? nil : $0 }
    let audioVersion = values["av"].flatMap(UInt8.init) ?? 0
    return (
      RoomDescriptor(
        id: RoomID(roomUUID),
        name: name,
        memberCount: max(1, count),
        sourceName: source,
        coordinatorID: MemberID(coordinatorUUID),
        coordinatorTerm: term,
        controlProtocolVersion: version,
        audioProtocolVersion: audioVersion
      ),
      audioPort
    )
  }
}

final class RoomDiscovery: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.zerosound.room-discovery")
  private var browser: NWBrowser?

  var onRoomsChanged: (@Sendable ([DiscoveredRoom]) -> Void)?
  var onError: (@Sendable (String) -> Void)?

  func start() {
    guard browser == nil else { return }
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: ZeroSoundProtocol.serviceType, domain: nil),
      using: tcpParameters()
    )
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        self?.onError?("Room discovery failed: \(error.localizedDescription)")
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      var rooms: [RoomID: DiscoveredRoom] = [:]
      for result in results {
        guard
          case .bonjour(let record) = result.metadata,
          let (descriptor, audioPort) = RoomAdvertisement.parse(record)
        else { continue }
        let room = DiscoveredRoom(
          descriptor: descriptor,
          endpoint: result.endpoint,
          audioPort: audioPort
        )
        if let existing = rooms[room.id] {
          let existingTerm = existing.descriptor.coordinatorTerm
          if descriptor.coordinatorTerm < existingTerm { continue }
          if descriptor.coordinatorTerm == existingTerm {
            let existingCoordinator = existing.descriptor.coordinatorID
            if descriptor.coordinatorID > existingCoordinator { continue }
            if descriptor.coordinatorID == existingCoordinator,
              String(describing: result.endpoint) >= String(describing: existing.endpoint)
            {
              continue
            }
          }
        }
        rooms[room.id] = room
      }
      self?.onRoomsChanged?(
        rooms.values.sorted {
          $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        })
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
    onRoomsChanged?([])
  }
}
