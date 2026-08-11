import Foundation
import ZeroSoundAudioIO

struct CapturedAudioChunk: Sendable {
  let samples: [Float]
  let frameCount: Int
  let firstHostTime: UInt64
}

enum SystemAudioCaptureError: LocalizedError {
  case creationFailed
  case startFailed(String)
  case invalidFormat

  var errorDescription: String? {
    switch self {
    case .creationFailed:
      "Could not create the system audio capture engine."
    case .startFailed(let message):
      message
    case .invalidFormat:
      "The system audio tap did not provide a valid sample rate."
    }
  }
}

final class SystemAudioCapture: @unchecked Sendable {
  private let capture: OpaquePointer
  private(set) var sampleRate = 0.0

  init() throws {
    guard let capture = ZSAudioCaptureCreate() else {
      throw SystemAudioCaptureError.creationFailed
    }
    self.capture = capture
  }

  deinit {
    ZSAudioCaptureDestroy(capture)
  }

  func start() throws {
    var errorBuffer = [CChar](repeating: 0, count: 512)
    let started = errorBuffer.withUnsafeMutableBufferPointer { buffer in
      ZSAudioCaptureStart(capture, buffer.baseAddress, buffer.count)
    }
    guard started else {
      let bytes = errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      let message = String(decoding: bytes, as: UTF8.self)
      throw SystemAudioCaptureError.startFailed(
        message.isEmpty ? "System audio capture could not start." : message
      )
    }

    sampleRate = ZSAudioCaptureGetSampleRate(capture)
    guard sampleRate > 0 else {
      stop()
      throw SystemAudioCaptureError.invalidFormat
    }
  }

  func stop() {
    ZSAudioCaptureStop(capture)
  }

  func read(maximumFrames: Int) -> CapturedAudioChunk? {
    var samples = [Float](repeating: 0, count: maximumFrames * 2)
    let result = samples.withUnsafeMutableBufferPointer { buffer in
      ZSAudioCaptureRead(capture, buffer.baseAddress, UInt32(maximumFrames))
    }
    guard result.frameCount > 0 else { return nil }

    let sampleCount = Int(result.frameCount) * 2
    if samples.count > sampleCount {
      samples.removeLast(samples.count - sampleCount)
    }
    return CapturedAudioChunk(
      samples: samples,
      frameCount: Int(result.frameCount),
      firstHostTime: result.firstHostTime
    )
  }

  var droppedFrameCount: UInt64 {
    ZSAudioCaptureGetDroppedFrameCount(capture)
  }
}
