import AppKit
import SwiftUI
import ZeroSoundCore

struct MenuBarPanel: View {
  @ObservedObject var controller: ZeroSoundController
  @ObservedObject var updates: UpdateController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let room = controller.room {
        insideRoom(room)
      } else if controller.isReconnecting {
        reconnecting
      } else {
        outsideRoom
      }
      Divider()
      HStack {
        Button("Open ZeroSound") { openMainWindow() }
          .buttonStyle(.plain)
        Spacer()
        Button("Updates…") { updates.checkForUpdates() }
          .buttonStyle(.plain)
          .disabled(!updates.canCheckForUpdates)
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
      }
      .font(.callout)
    }
    .padding(15)
    .frame(width: 340)
  }

  private var outsideRoom: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Nearby rooms").font(.headline)
          Text("Join and this Mac becomes a speaker")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "dot.radiowaves.left.and.right")
          .foregroundStyle(RoomPalette.accent)
      }

      if controller.nearbyRooms.isEmpty {
        Text("No rooms visible")
          .font(.callout).foregroundStyle(.secondary).padding(.vertical, 5)
      } else {
        ForEach(controller.nearbyRooms.prefix(5)) { room in
          Button {
            controller.join(room)
          } label: {
            HStack {
              Image(systemName: "hifispeaker.2.fill")
                .foregroundStyle(room.descriptor.isCompatible ? RoomPalette.accent : .secondary)
              VStack(alignment: .leading, spacing: 1) {
                Text(room.descriptor.name)
                Text(
                  "\(room.descriptor.memberCount) Mac\(room.descriptor.memberCount == 1 ? "" : "s")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(room.descriptor.isCompatible ? "Join" : "Update required")
                .font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(!room.descriptor.isCompatible)
          .padding(.vertical, 4)
        }
      }

      Button {
        controller.createRoom()
      } label: {
        Label("Create Office Room", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(RoomPalette.accent)
    }
  }

  private var reconnecting: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Rejoining the room…", systemImage: "arrow.triangle.2.circlepath")
        .font(.headline).foregroundStyle(.orange)
      Text(controller.status).font(.caption).foregroundStyle(.secondary)
      Button("Leave Room", role: .destructive) { controller.leaveRoom() }
    }
  }

  private func insideRoom(_ room: RoomSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(room.name).font(.headline)
          Text("\(room.members.count) Mac\(room.members.count == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        HealthBadge(severity: controller.healthSeverity)
      }

      HStack(spacing: 10) {
        Image(systemName: room.audioSource.isLive ? "waveform" : "speaker.slash")
          .foregroundStyle(room.audioSource.isLive ? RoomPalette.accent : .secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(room.sourceMember.map { "Audio from \($0.name)" } ?? "No audio playing")
            .font(.callout.weight(.medium))
          Text(room.audioSource.isLive ? "System audio · Live" : "Room ready")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)

      if controller.isLocalSource {
        Button {
          controller.stopAudio()
        } label: {
          Label("Stop audio", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(RoomPalette.accent)
      } else {
        Button {
          controller.playFromThisMac()
        } label: {
          Label(
            room.audioSource.memberID == nil ? "Play from this Mac" : "Take over audio",
            systemImage: "play.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(RoomPalette.accent)
      }

      HStack {
        Button("Open Room") { openMainWindow() }.buttonStyle(.plain)
        Spacer()
        Button("Leave Room", role: .destructive) { controller.leaveRoom() }
          .buttonStyle(.plain)
      }
      .font(.callout)
    }
  }

  private func openMainWindow() {
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
