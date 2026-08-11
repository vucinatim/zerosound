import SwiftUI
import ZeroSoundCore

struct RoomMemberView: View {
  let member: RoomMember
  let isLocal: Bool
  let isSource: Bool

  var body: some View {
    VStack(spacing: 11) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
          .fill(isSource ? RoomPalette.accent.opacity(0.13) : Color.secondary.opacity(0.08))
          .frame(width: 72, height: 62)
        Image(systemName: "laptopcomputer")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(isSource ? RoomPalette.accent : .secondary)
          .frame(width: 72, height: 62)
        Circle()
          .fill(connectionColor)
          .frame(width: 11, height: 11)
          .overlay(Circle().stroke(.background, lineWidth: 2))
          .offset(x: 2, y: 2)
      }

      VStack(spacing: 3) {
        Text(member.name).font(.headline).lineLimit(1)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }

      if isSource {
        LiveLevelView(level: member.audioLevel, active: true)
      } else {
        Text(connectionText)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(height: 25)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, minHeight: 178)
    .background(
      isSource ? RoomPalette.accent.opacity(0.055) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 19, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 19, style: .continuous)
        .stroke(isSource ? RoomPalette.accent.opacity(0.38) : .clear, lineWidth: 1.5)
    }
    .shadow(color: isSource ? RoomPalette.accent.opacity(0.12) : .clear, radius: 15, y: 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  private var subtitle: String {
    if isSource { return isLocal ? "Playing from this Mac" : "Current audio source" }
    if isLocal { return "This Mac · Speaker" }
    return "Room speaker"
  }

  private var connectionText: String {
    switch member.connection {
    case .ready:
      member.roundTripNanoseconds.map {
        String(format: "Ready · %.0f ms", Double($0) / 1_000_000)
      } ?? "Ready"
    case .synchronizing: "Synchronizing"
    case .reconnecting: "Reconnecting"
    }
  }

  private var connectionColor: Color {
    switch member.connection {
    case .ready: .green
    case .synchronizing: RoomPalette.accent
    case .reconnecting: .orange
    }
  }

  private var accessibilitySummary: String {
    "\(member.name), \(subtitle), \(connectionText)"
  }
}
