import AppKit
import SwiftUI
import ZeroSoundCore

struct RoomDiagnosticsView: View {
  @ObservedObject var controller: ZeroSoundController
  let snapshot: RoomSnapshot
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(controller.healthSeverity.title).font(.title2.bold())
              Text(controller.roomHealth.summary).foregroundStyle(.secondary)
            }
            Spacer()
            HealthBadge(severity: controller.healthSeverity)
          }

          diagnosticsGrid

          VStack(alignment: .leading, spacing: 12) {
            Text("Members").font(.headline)
            ForEach(snapshot.members) { member in
              memberRow(member)
              if member.id != snapshot.members.last?.id { Divider() }
            }
          }
          .padding(18)
          .roomSurface()

          DisclosureGroup("Technical room details") {
            VStack(alignment: .leading, spacing: 6) {
              LabeledContent("Room ID", value: snapshot.id.description)
              LabeledContent("Coordinator term", value: String(snapshot.coordinatorTerm))
              LabeledContent("Stream generation", value: String(snapshot.streamGeneration))
              LabeledContent(
                "Protocol",
                value: "\(ZeroSoundProtocol.controlVersion).\(ZeroSoundProtocol.audioVersion)")
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.top, 10)
          }
        }
        .padding(24)
      }
      .frame(minWidth: 620, minHeight: 560)
      .navigationTitle("Room Diagnostics")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Copy Diagnostics") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.diagnosticsReport(), forType: .string)
          }
        }
      }
    }
  }

  private var diagnosticsGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      metric(
        "Round trip",
        controller.roundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "Local")
      metric("Worst round trip", formattedNanoseconds(localMember?.worstRoundTripNanoseconds))
      metric(
        "Playback queue",
        String(format: "%.0f ms", controller.playbackHealth.bufferDepthMilliseconds))
      metric(
        "Phase error",
        controller.playbackHealth.phaseErrorMilliseconds.map {
          String(format: "%+.2f ms", $0)
        } ?? "Measuring…"
      )
      metric(
        "Concealed · 10 sec",
        String(controller.playbackHealth.recentMissingPackets))
      metric(
        "Reordered · 10 sec",
        String(controller.playbackHealth.recentReorderedPackets))
      metric("Underruns", String(controller.playbackHealth.rendererUnderruns))
      metric("Automatic resyncs", String(controller.playbackHealth.resynchronizations))
      metric("Last recovery", controller.playbackHealth.lastRecoveryReason ?? "None")
      metric(
        "Output latency",
        String(format: "%.1f ms", controller.playbackHealth.outputLatencyMilliseconds))
      metric(
        "Playback correction",
        String(format: "%.0f ppm", controller.playbackHealth.playbackRatePartsPerMillion))
      metric(
        "Room clock skew",
        controller.clockSkewPartsPerMillion.map { String(format: "%+.1f ppm", $0) }
          ?? "Measuring…")
      metric("Control plane", controller.transportDiagnostics.control.rawValue.capitalized)
      metric("Audio plane", controller.transportDiagnostics.audio.rawValue.capitalized)
      metric("Join stage", controller.transportDiagnostics.joinStage)
      metric(
        "Audio dropped before send",
        String(controller.transportDiagnostics.audioDatagramsDroppedBeforeSend))
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .roomSurface(radius: 13)
  }

  private func memberRow(_ member: RoomMember) -> some View {
    let health =
      member.id == controller.localMemberID
      ? controller.playbackHealth : member.playbackHealth
    return HStack(spacing: 12) {
      Image(systemName: "laptopcomputer").foregroundStyle(.secondary).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(member.name).font(.callout.weight(.semibold))
        Text(
          "\(member.connection.rawValue.capitalized) · ZeroSound \(member.appVersion)"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("Now \(formattedNanoseconds(member.roundTripNanoseconds))")
        Text(phaseDescription(health))
          .foregroundStyle(.tertiary)
      }
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
  }

  private var localMember: RoomMember? {
    snapshot.members.first { $0.id == controller.localMemberID }
  }

  private func formattedNanoseconds(_ value: UInt64?) -> String {
    value.map { String(format: "%.1f ms", Double($0) / 1_000_000) } ?? "Local"
  }

  private func phaseDescription(_ health: PlaybackHealth) -> String {
    health.phaseErrorMilliseconds.map { String(format: "Phase %+.1f ms", $0) }
      ?? "Phase measuring"
  }

}
