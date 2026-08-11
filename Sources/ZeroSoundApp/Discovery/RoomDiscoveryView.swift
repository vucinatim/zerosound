import SwiftUI
import ZeroSoundCore

struct RoomDiscoveryView: View {
  @ObservedObject var controller: ZeroSoundController

  var body: some View {
    ScrollView {
      VStack(spacing: 34) {
        VStack(spacing: 12) {
          Image(systemName: "waveform.badge.plus")
            .font(.system(size: 46, weight: .medium))
            .foregroundStyle(RoomPalette.accent)
            .accessibilityHidden(true)
          Text("Bring the room together")
            .font(.system(size: 34, weight: .bold, design: .rounded))
          Text("Join a nearby room and this Mac becomes a synchronized speaker.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("Nearby rooms")
            .font(.headline)
            .foregroundStyle(.secondary)

          if controller.nearbyRooms.isEmpty {
            HStack(spacing: 13) {
              Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text("No rooms visible yet").font(.headline)
                Text("Create Office Room and invite the Macs around you.")
                  .font(.callout).foregroundStyle(.secondary)
              }
              Spacer()
            }
            .padding(20)
            .roomSurface()
          } else {
            ForEach(controller.nearbyRooms) { room in
              Button {
                controller.join(room)
              } label: {
                HStack(spacing: 14) {
                  Image(systemName: "hifispeaker.2.fill")
                    .font(.title2)
                    .foregroundStyle(room.descriptor.isCompatible ? RoomPalette.accent : .secondary)
                    .frame(width: 38)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(room.descriptor.name).font(.headline)
                    Text(roomSummary(room.descriptor))
                      .font(.callout).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(room.descriptor.isCompatible ? "Join" : "Update required")
                    .font(.callout.weight(.semibold))
                  if room.descriptor.isCompatible {
                    Image(systemName: "chevron.right")
                      .font(.caption.bold())
                  }
                }
                .padding(18)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!room.descriptor.isCompatible)
              .roomSurface()
              .accessibilityHint(
                room.descriptor.isCompatible
                  ? "Joins immediately and uses this Mac as a speaker"
                  : "Install the same ZeroSound version on every Mac"
              )
            }
          }

          Button {
            controller.createRoom()
          } label: {
            Label("Create Office Room", systemImage: "plus")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 5)
          }
          .buttonStyle(.borderedProminent)
          .tint(RoomPalette.accent)
          .controlSize(.large)
          .accessibilityHint("Creates and joins the room immediately")
        }
        .frame(maxWidth: 620)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 38)
      .padding(.vertical, 54)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func roomSummary(_ room: RoomDescriptor) -> String {
    let members = "\(room.memberCount) Mac\(room.memberCount == 1 ? "" : "s")"
    return room.sourceName.map { "\(members) · Audio from \($0)" } ?? "\(members) · Ready"
  }
}
