import SwiftUI
import ZeroSoundCore

struct RoomView: View {
  @ObservedObject var controller: ZeroSoundController
  let snapshot: RoomSnapshot
  @State private var showsDiagnostics = false
  @State private var showsRename = false
  @State private var renameDraft = ""
  @State private var showsTakeoverWarning = false

  var body: some View {
    ScrollView {
      VStack(spacing: 30) {
        header
        sourceContext
        memberGrid
        statusLine
      }
      .padding(.horizontal, 34)
      .padding(.top, 28)
      .padding(.bottom, 112)
      .frame(maxWidth: 1100)
      .frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
    .sheet(isPresented: $showsDiagnostics) {
      RoomDiagnosticsView(controller: controller, snapshot: snapshot)
    }
    .alert("Rename Room", isPresented: $showsRename) {
      TextField("Room name", text: $renameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { controller.renameRoom(renameDraft) }
    } message: {
      Text("Everyone in the room will see the new name.")
    }
    .confirmationDialog(
      "Take over room audio?",
      isPresented: $showsTakeoverWarning,
      titleVisibility: .visible
    ) {
      Button("Take Over Audio") { controller.playFromThisMac() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This stops audio from \(snapshot.sourceMember?.name ?? "the current Mac") before starting from this Mac."
      )
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Button {
          renameDraft = snapshot.name
          showsRename = true
        } label: {
          HStack(spacing: 8) {
            Text(snapshot.name)
              .font(.system(size: 32, weight: .bold, design: .rounded))
            Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename \(snapshot.name)")
        Text("\(snapshot.members.count) Mac\(snapshot.members.count == 1 ? "" : "s") in this room")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        showsDiagnostics = true
      } label: {
        HStack(spacing: 10) {
          HealthBadge(severity: controller.healthSeverity)
          Image(systemName: "chevron.right")
            .font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens technical room diagnostics")
    }
    .frame(maxWidth: .infinity)
  }

  private var sourceContext: some View {
    VStack(spacing: 7) {
      if let source = snapshot.sourceMember {
        Text("SYSTEM AUDIO FROM")
          .font(.caption2.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
        Text(source.name)
          .font(.title2.bold())
        HStack(spacing: 8) {
          LiveLevelView(level: source.audioLevel, active: snapshot.audioSource.isLive)
          Text(snapshot.audioSource.isLive ? "Live audio" : "Preparing audio")
            .font(.callout).foregroundStyle(.secondary)
        }
      } else {
        Image(systemName: "speaker.wave.2")
          .font(.title2).foregroundStyle(.secondary)
        Text("The room is ready")
          .font(.title2.bold())
        Text("Any member can play system audio for everyone.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 22)
    .accessibilityElement(children: .combine)
  }

  private var memberGrid: some View {
    VStack(spacing: 22) {
      if let source = snapshot.sourceMember {
        memberTile(source, isSource: true)
          .frame(width: 260)
          .scaleEffect(1.03)
          .padding(.bottom, 5)
      }

      ForEach(Array(memberRows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 18) {
          ForEach(row) { member in
            memberTile(member, isSource: false)
              .frame(width: tileWidth)
          }
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: 880)
  }

  private func memberTile(_ member: RoomMember, isSource: Bool) -> some View {
    RoomMemberView(
      member: member,
      isLocal: member.id == controller.localMemberID,
      isSource: isSource
    )
  }

  private var nonSourceMembers: [RoomMember] {
    snapshot.members
      .filter { $0.id != snapshot.audioSource.memberID }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var memberRows: [[RoomMember]] {
    let members = nonSourceMembers
    guard !members.isEmpty else { return [] }
    let columns: Int
    switch members.count {
    case 1: columns = 1
    case 2: columns = 2
    case 3: columns = 3
    case 4: columns = 2
    case 5, 6: columns = 3
    default: columns = 4
    }
    return stride(from: 0, to: members.count, by: columns).map {
      Array(members[$0..<min($0 + columns, members.count)])
    }
  }

  private var tileWidth: CGFloat {
    nonSourceMembers.count >= 7 ? 190 : 220
  }

  private var statusLine: some View {
    Text(roomStatus)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .textSelection(.enabled)
  }

  private var roomStatus: String {
    if snapshot.audioSource.isLive, let source = snapshot.sourceMember {
      return "Playing system audio from \(source.name)."
    }
    if let source = snapshot.sourceMember {
      return "Preparing system audio from \(source.name)…"
    }
    return "\(snapshot.name) is ready."
  }

  private var actionBar: some View {
    HStack(spacing: 12) {
      if controller.isLocalSource {
        Button {
          controller.stopAudio()
        } label: {
          Label("Stop audio", systemImage: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(RoomPalette.accent)
        .controlSize(.large)
      } else {
        Button {
          if snapshot.audioSource.memberID == nil {
            controller.playFromThisMac()
          } else {
            showsTakeoverWarning = true
          }
        } label: {
          Label(
            snapshot.audioSource.memberID == nil ? "Play from this Mac" : "Take over audio",
            systemImage: "play.fill"
          )
        }
        .buttonStyle(.borderedProminent)
        .tint(RoomPalette.accent)
        .controlSize(.large)
        .help(
          snapshot.audioSource.memberID == nil
            ? "Share this Mac's system audio with the room"
            : "Stops the current audio, then starts from this Mac"
        )
      }

      Spacer()

      Button("Leave Room", role: .destructive) { controller.leaveRoom() }
        .controlSize(.large)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 16)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}
