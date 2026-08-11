import AppKit
import SwiftUI
import ZeroSoundCore

@main
struct ZeroSoundApp: App {
  @StateObject private var controller: ZeroSoundController
  @StateObject private var lifecycle: SystemLifecycle
  @StateObject private var updates: UpdateController

  init() {
    let controller = ZeroSoundController()
    _controller = StateObject(wrappedValue: controller)
    _lifecycle = StateObject(wrappedValue: SystemLifecycle(controller: controller))
    _updates = StateObject(wrappedValue: UpdateController())
  }

  var body: some Scene {
    WindowGroup("ZeroSound", id: "main") {
      AppShell(controller: controller)
        .frame(minWidth: 900, minHeight: 620)
    }
    .defaultSize(width: 1_000, height: 700)
    .windowResizability(.contentMinSize)
    .commands {
      RoomCommands(controller: controller)
      UpdateCommands(updates: updates)
    }

    MenuBarExtra {
      MenuBarPanel(controller: controller, updates: updates)
    } label: {
      Image(systemName: menuBarSymbol)
        .accessibilityLabel("ZeroSound")
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(updates: updates)
        .frame(width: 440, height: 300)
    }
  }

  private var menuBarSymbol: String {
    if controller.isAudioLive { return "waveform.circle.fill" }
    return controller.isInRoom ? "dot.radiowaves.left.and.right" : "waveform.circle"
  }
}

private struct UpdateCommands: Commands {
  @ObservedObject var updates: UpdateController

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { updates.checkForUpdates() }
        .disabled(!updates.canCheckForUpdates)
    }
  }
}

private struct RoomCommands: Commands {
  @ObservedObject var controller: ZeroSoundController

  var body: some Commands {
    CommandMenu("Room") {
      if controller.isInRoom {
        if controller.isLocalSource {
          Button("Stop Audio") { controller.stopAudio() }
        } else {
          Button("Play from This Mac") { controller.playFromThisMac() }
        }
        Divider()
        Button("Leave Room") { controller.leaveRoom() }
          .keyboardShortcut(".", modifiers: [.command])
      } else if controller.isReconnecting {
        Button("Leave Room") { controller.leaveRoom() }
      } else {
        Button("Create Office Room") { controller.createRoom() }
          .keyboardShortcut(.return, modifiers: [.command])
      }
    }
  }
}

private struct SettingsView: View {
  @ObservedObject var updates: UpdateController

  var body: some View {
    Form {
      Section("Playback") {
        LabeledContent("Safety buffer", value: "300 ms")
        Text("ZeroSound uses a fixed buffer to absorb office Wi-Fi jitter.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Section("Version") {
        LabeledContent("ZeroSound", value: ZeroSoundProtocol.appVersion)
        LabeledContent(
          "Room protocol",
          value: "\(ZeroSoundProtocol.controlVersion).\(ZeroSoundProtocol.audioVersion)")
        Text("Install the same ZeroSound build on every Mac in a room.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Button("Check for Updates…") { updates.checkForUpdates() }
          .disabled(!updates.canCheckForUpdates)
        if let error = updates.configurationError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}
