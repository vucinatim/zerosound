import SwiftUI
import ZeroSoundCore

struct AppShell: View {
  @ObservedObject var controller: ZeroSoundController

  var body: some View {
    Group {
      switch controller.membership {
      case .discovering, .outsideRoom:
        RoomDiscoveryView(controller: controller)
      case .creating, .joining, .leaving:
        progressView
      case .reconnecting:
        reconnectingView
      case .inRoom(let snapshot):
        RoomView(controller: controller, snapshot: snapshot)
      }
    }
  }

  private var progressView: some View {
    VStack(spacing: 16) {
      ProgressView().controlSize(.large)
      Text(controller.status).font(.title3).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var reconnectingView: some View {
    VStack(spacing: 18) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 38)).foregroundStyle(.orange)
      Text("Rejoining the room").font(.title2.bold())
      Text(controller.status).foregroundStyle(.secondary)
      Button("Leave Room", role: .destructive) { controller.leaveRoom() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
