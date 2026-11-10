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

  /// Closing the window hides ZipTop in the menu bar while recordings are
  /// due; it must not quit.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// Cmd+Q, Quit in the app menu, or logging out: let Dart shut down the way
  /// closing the window does (offer to keep recording, release the streams),
  /// then it quits through window_manager's destroy, which lands here again
  /// with terminateAllowed set.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminateAllowed, let channel = channel else { return .terminateNow }
    channel.invokeMethod("quitRequested", arguments: nil)
    return .terminateCancel
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
