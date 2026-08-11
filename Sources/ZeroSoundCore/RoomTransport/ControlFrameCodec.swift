import Foundation

enum ControlFrameError: Error, Equatable {
  case emptyFrame
  case frameTooLarge(Int)
  case truncatedFrame
}

enum ControlFrameCodec {
  static let maximumPayloadBytes = 256 * 1_024
  private static let headerBytes = MemoryLayout<UInt32>.size

  static func encode(
    _ payload: Data,
    maximumPayloadBytes: Int = maximumPayloadBytes
  ) throws -> Data {
    guard !payload.isEmpty else { throw ControlFrameError.emptyFrame }
    guard payload.count <= maximumPayloadBytes, payload.count <= Int(UInt32.max) else {
      throw ControlFrameError.frameTooLarge(payload.count)
    }

    var length = UInt32(payload.count).bigEndian
    var frame = Data(capacity: headerBytes + payload.count)
    Swift.withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }
}

struct ControlFrameDecoder: Sendable {
  private static let headerBytes = MemoryLayout<UInt32>.size

  private let maximumPayloadBytes: Int
  private var storage = Data()
  private var readOffset = 0

  init(maximumPayloadBytes: Int = ControlFrameCodec.maximumPayloadBytes) {
    self.maximumPayloadBytes = max(1, maximumPayloadBytes)
  }

  mutating func append(_ bytes: Data) throws -> [Data] {
    storage.append(bytes)
    var frames: [Data] = []

    while storage.count - readOffset >= Self.headerBytes {
      let payloadLength = Int(readLength(at: readOffset))
      guard payloadLength > 0 else {
        reset()
        throw ControlFrameError.emptyFrame
      }
      guard payloadLength <= maximumPayloadBytes else {
        reset()
        throw ControlFrameError.frameTooLarge(payloadLength)
      }

      let payloadOffset = readOffset + Self.headerBytes
      guard storage.count - payloadOffset >= payloadLength else { break }
      frames.append(storage.subdata(in: payloadOffset..<(payloadOffset + payloadLength)))
      readOffset = payloadOffset + payloadLength
    }

    compactStorage()
    return frames
  }

  mutating func finish() throws {
    guard storage.count == readOffset else {
      reset()
      throw ControlFrameError.truncatedFrame
    }
    reset()
  }

  private func readLength(at offset: Int) -> UInt32 {
    storage[offset..<(offset + Self.headerBytes)].reduce(UInt32.zero) {
      ($0 << 8) | UInt32($1)
    }
  }

  private mutating func compactStorage() {
    guard readOffset > 0 else { return }
    if readOffset == storage.count {
      reset()
    } else if readOffset >= 4_096 {
      storage.removeSubrange(0..<readOffset)
      readOffset = 0
    }
  }

  private mutating func reset() {
    storage.removeAll(keepingCapacity: true)
    readOffset = 0
  }
}
