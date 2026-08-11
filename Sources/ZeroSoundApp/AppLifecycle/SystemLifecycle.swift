import AppKit
import Combine
import ZeroSoundCore

@MainActor
final class SystemLifecycle: ObservableObject {
  private var observers: [NotificationObservation] = []

  init(controller: ZeroSoundController) {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      NotificationObservation(
        center: center,
        token: center.addObserver(
          forName: NSWorkspace.willSleepNotification,
          object: nil,
          queue: .main
        ) { [weak controller] _ in
          Task { @MainActor in
            controller?.prepareForSystemSleep()
          }
        }
      )
    )
    observers.append(
      NotificationObservation(
        center: center,
        token: center.addObserver(
          forName: NSWorkspace.didWakeNotification,
          object: nil,
          queue: .main
        ) { [weak controller] _ in
          Task { @MainActor in
            controller?.resumeAfterSystemWake()
          }
        }
      )
    )
  }
}

private final class NotificationObservation: @unchecked Sendable {
  private let center: NotificationCenter
  private let token: NSObjectProtocol

  init(center: NotificationCenter, token: NSObjectProtocol) {
    self.center = center
    self.token = token
  }

  deinit {
    center.removeObserver(token)
  }
}
