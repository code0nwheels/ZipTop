import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Talks to lib/core/platform/app_channel.dart.
  private var channel: FlutterMethodChannel?

  /// Set by Dart once it has released its server slots and closed any
  /// recording, just before it quits.
  private var terminateAllowed = false

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
  /// signing out, or Dart not answering) ZipTop quits now, so a quit is never
  /// swallowed.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminateAllowed, let channel = channel else { return .terminateNow }
    channel.invokeMethod("quitRequested", arguments: nil) { [weak self] result in
      if (result as? Bool) == true { return }
      self?.terminateAllowed = true
      NSApp.terminate(nil)
    }
    return .terminateCancel
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
