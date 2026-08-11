import Foundation

struct AudioPacket: Equatable, Sendable {
  static let magic: [UInt8] = [0x5A, 0x53, 0x41, 0x32]  // ZSA2
  static let headerSize = 48

  let sequence: UInt32
  let presentationNanoseconds: UInt64
  let sampleRate: UInt32
  let streamGeneration: UInt64
  let sourceID: MemberID
  let samples: [Int16]

  var frameCount: Int { samples.count / 2 }

  init(
    sequence: UInt32,
    presentationNanoseconds: UInt64,
    sampleRate: UInt32,
    streamGeneration: UInt64 = 1,
    sourceID: MemberID = MemberID(UUID()),
    floatSamples: [Float]
  ) {
    self.sequence = sequence
    self.presentationNanoseconds = presentationNanoseconds
    self.sampleRate = sampleRate
    self.streamGeneration = streamGeneration
    self.sourceID = sourceID
    samples = floatSamples.map { sample in
      let clamped = max(-1, min(1, sample))
      return Int16((clamped * Float(Int16.max)).rounded())
    }
  }

  private init(
    sequence: UInt32,
    presentationNanoseconds: UInt64,
    sampleRate: UInt32,
    streamGeneration: UInt64,
    sourceID: MemberID,
    samples: [Int16]
  ) {
    self.sequence = sequence
    self.presentationNanoseconds = presentationNanoseconds
    self.sampleRate = sampleRate
    self.streamGeneration = streamGeneration
    self.sourceID = sourceID
    self.samples = samples
  }

  func encode() -> Data {
    var data = Data(capacity: Self.headerSize + samples.count * MemoryLayout<Int16>.size)
    data.append(contentsOf: Self.magic)
    data.append(UInt8(ZeroSoundProtocol.audioVersion))
    data.append(2)  // Stereo.
    data.appendBigEndian(UInt16(frameCount))
    data.appendBigEndian(sequence)
    data.appendBigEndian(presentationNanoseconds)
    data.appendBigEndian(sampleRate)
    data.appendBigEndian(streamGeneration)
    var uuid = sourceID.rawValue.uuid
    Swift.withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    for sample in samples {
      data.appendBigEndian(UInt16(bitPattern: sample))
    }
    return data
  }

  static func decode(_ data: Data) -> AudioPacket? {
    guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return nil }
    var cursor = DataCursor(data: data, offset: 4)
    guard
      cursor.readUInt8() == UInt8(ZeroSoundProtocol.audioVersion),
      cursor.readUInt8() == 2,
      let frameCount = cursor.readUInt16(),
      let sequence = cursor.readUInt32(),
      let presentation = cursor.readUInt64(),
      let sampleRate = cursor.readUInt32(),
      let streamGeneration = cursor.readUInt64(),
      let sourceBytes = cursor.readBytes(count: 16),
      frameCount > 0,
      sampleRate > 0,
      data.count == headerSize + Int(frameCount) * 2 * MemoryLayout<Int16>.size
    else { return nil }

    let sourceUUID = UUID(
      uuid: (
        sourceBytes[0], sourceBytes[1], sourceBytes[2], sourceBytes[3],
        sourceBytes[4], sourceBytes[5], sourceBytes[6], sourceBytes[7],
        sourceBytes[8], sourceBytes[9], sourceBytes[10], sourceBytes[11],
        sourceBytes[12], sourceBytes[13], sourceBytes[14], sourceBytes[15]
      ))

    var samples: [Int16] = []
    samples.reserveCapacity(Int(frameCount) * 2)
    for _ in 0..<(Int(frameCount) * 2) {
      guard let value = cursor.readUInt16() else { return nil }
      samples.append(Int16(bitPattern: value))
    }
    return AudioPacket(
      sequence: sequence,
      presentationNanoseconds: presentation,
      sampleRate: sampleRate,
      streamGeneration: streamGeneration,
      sourceID: MemberID(sourceUUID),
      samples: samples
    )
  }

  func retimed(to presentationNanoseconds: UInt64) -> Self {
    Self(
      sequence: sequence,
      presentationNanoseconds: presentationNanoseconds,
      sampleRate: sampleRate,
      streamGeneration: streamGeneration,
      sourceID: sourceID,
      samples: samples
    )
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { bytes in
      append(contentsOf: bytes)
    }
  }
}

private struct DataCursor {
  let data: Data
  var offset: Int

  mutating func readUInt8() -> UInt8? {
    guard offset < data.count else { return nil }
    defer { offset += 1 }
    return data[offset]
  }

  mutating func readUInt16() -> UInt16? { readInteger() }
  mutating func readUInt32() -> UInt32? { readInteger() }
  mutating func readUInt64() -> UInt64? { readInteger() }

  mutating func readBytes(count: Int) -> [UInt8]? {
    guard count >= 0, offset + count <= data.count else { return nil }
    defer { offset += count }
    return Array(data[offset..<(offset + count)])
  }

  private mutating func readInteger<T: FixedWidthInteger>() -> T? {
    let size = MemoryLayout<T>.size
    guard offset + size <= data.count else { return nil }
    var value: T = 0
    for byte in data[offset..<(offset + size)] {
      value = (value << 8) | T(byte)
    }
    offset += size
    return value
  }
}
