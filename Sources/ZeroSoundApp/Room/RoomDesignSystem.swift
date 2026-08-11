import SwiftUI
import ZeroSoundCore

enum RoomPalette {
  static let accent = Color(red: 0.12, green: 0.48, blue: 0.96)

  static func health(_ severity: RoomHealthSeverity) -> Color {
    switch severity {
    case .excellent: .green
    case .stabilizing: accent
    case .degraded: .orange
    case .actionRequired: .red
    }
  }
}

struct HealthBadge: View {
  let severity: RoomHealthSeverity

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(RoomPalette.health(severity)).frame(width: 7, height: 7)
      Text(severity.title)
    }
    .font(.callout.weight(.medium))
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Room health: \(severity.title)")
  }
}

struct LiveLevelView: View {
  let level: Float
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<7, id: \.self) { index in
        Capsule()
          .fill(active ? RoomPalette.accent : Color.secondary.opacity(0.3))
          .frame(width: 3, height: barHeight(index))
      }
    }
    .frame(height: 25)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
    .accessibilityElement()
    .accessibilityLabel("Live audio level")
    .accessibilityValue(active && level > 0.01 ? "Audio detected" : "Quiet")
  }

  private func barHeight(_ index: Int) -> CGFloat {
    guard active else { return 5 }
    let shape: [Float] = [0.32, 0.55, 0.82, 1, 0.74, 0.48, 0.28]
    return 5 + CGFloat(max(0.08, level) * shape[index]) * 20
  }
}

extension View {
  func roomSurface(radius: CGFloat = 18) -> some View {
    background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}
