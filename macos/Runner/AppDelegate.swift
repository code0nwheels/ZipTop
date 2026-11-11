import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Talks to lib/core/platform/app_channel.dart.
  private var channel: FlutterMethodChannel?

  /// Set by Dart once it has released its server slots and closed any
  /// recording, just before it quits.
  private var terminateAllowed = false

  /// Counts quit requests, so a late fallback for an answered one does
  /// nothing.
  private var quitRequest = 0

  /// How long Dart has to answer a quit request before ZipTop quits anyway.
  private let quitAnswerTimeout: TimeInterval = 5

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "ziptop/app", binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "allowTerminate":
          self?.terminateAllowed = true
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      self.channel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  /// Closing the last window quits, as it does on Windows and Linux. While
  /// signed in, the shell intercepts closing (window_manager's prevent-close)
  /// and hides the window to the menu bar instead, which isn't closing it, so
  /// this only applies to screens such as pairing.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  /// Cmd+Q, Quit in the app menu or Dock, logging out, or closing the last
  /// window. Dart gets the first say: the signed-in shell shuts down the way
  /// closing the window does (offer to keep recording, release the streams)
  /// and quits through window_manager's destroy, which lands here again with
  /// terminateAllowed set. If nothing in Dart takes it (pairing screen, after
  /// signing out) ZipTop quits now, and if Dart doesn't answer within
  /// quitAnswerTimeout it quits anyway, so a quit is never swallowed.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminateAllowed, let channel = channel else { return .terminateNow }
    quitRequest += 1
    let request = quitRequest
    var answered = false
    channel.invokeMethod("quitRequested", arguments: nil) { [weak self] result in
      answered = true
      if (result as? Bool) == true { return }
      self?.quitNow()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quitAnswerTimeout) { [weak self] in
      guard let self = self, !answered, request == self.quitRequest else { return }
      self.quitNow()
    }
    return .terminateCancel
  }

  private func quitNow() {
    terminateAllowed = true
    NSApp.terminate(nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
