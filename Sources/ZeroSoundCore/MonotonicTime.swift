import AVFAudio
import Darwin

public enum MonotonicTime {
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  public static func nowNanoseconds() -> UInt64 {
    ticksToNanoseconds(mach_absolute_time())
  }

  public static func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
    let value = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    return UInt64(value.rounded())
  }

  public static func nanosecondsToTicks(_ nanoseconds: UInt64) -> UInt64 {
    let value = Double(nanoseconds) * Double(timebase.denom) / Double(timebase.numer)
    return UInt64(value.rounded())
  }

  public static func audioTime(nanoseconds: UInt64) -> AVAudioTime {
    AVAudioTime(hostTime: nanosecondsToTicks(nanoseconds))
  }
}
