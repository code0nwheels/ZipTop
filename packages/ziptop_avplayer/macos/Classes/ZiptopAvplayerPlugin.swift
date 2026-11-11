import AVFoundation
import AVKit
import Cocoa
import CoreMedia
import CoreVideo
import FlutterMacOS
import QuartzCore

/// AVPlayer for ZipTop on macOS: plays HLS into Flutter textures and shows
/// the system AirPlay picker. The Dart side is lib/player/av_player.dart.
public class ZiptopAvplayerPlugin: NSObject, FlutterPlugin, AVRoutePickerViewDelegate {
  private let registrar: FlutterPluginRegistrar
  private var players: [Int64: ZipAVPlayer] = [:]
  private var nextId: Int64 = 1
  private var routePicker: AVRoutePickerView?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ziptop/avplayer", binaryMessenger: registrar.messenger)
    let instance = ZiptopAvplayerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "create" {
      let id = nextId
      nextId += 1
      let player = ZipAVPlayer(
        id: id,
        textures: registrar.textures,
        messenger: registrar.messenger,
        bufferSeconds: (args["bufferSeconds"] as? NSNumber)?.doubleValue ?? 30,
        allowsAirPlay: (args["allowsAirPlay"] as? Bool) ?? false)
      players[id] = player
      result(["id": id, "textureId": player.textureId])
      return
    }
    guard let id = (args["id"] as? NSNumber)?.int64Value, let player = players[id] else {
      result(FlutterError(code: "no_player", message: "No such player", details: nil))
      return
    }
    switch call.method {
    case "open":
      guard let text = args["url"] as? String, let url = URL(string: text) else {
        result(FlutterError(code: "bad_url", message: "Not a stream URL", details: nil))
        return
      }
      player.open(
        url: url,
        token: (args["open"] as? NSNumber)?.intValue ?? 0,
        userAgent: args["userAgent"] as? String,
        headers: args["headers"] as? [String: String] ?? [:],
        peakBitRate: (args["peakBitRate"] as? NSNumber)?.doubleValue ?? 0)
    case "stop":
      player.stop()
    case "pause":
      player.player.pause()
    case "resume":
      player.player.play()
    case "playOrPause":
      if player.player.timeControlStatus == .paused {
        player.player.play()
      } else {
        player.player.pause()
      }
    case "setVolume":
      player.player.volume = (args["volume"] as? NSNumber)?.floatValue ?? 1
    case "setMuted":
      player.player.isMuted = (args["muted"] as? Bool) ?? false
    case "setPeakBitRate":
      player.setPeakBitRate((args["peakBitRate"] as? NSNumber)?.doubleValue ?? 0)
    case "selectAudio":
      player.selectAudio(args["track"] as? String)
    case "selectCaptions":
      player.selectCaptions(args["track"] as? String)
    case "showRoutePicker":
      showRoutePicker(for: player, args: args)
    case "dispose":
      player.dispose()
      players[id] = nil
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  /// AVRoutePickerView has no call that opens its menu, so a clear one is
  /// laid over the Flutter button (x, y, width, height in the Flutter view's
  /// coordinates) and its own button pressed. It goes away when the menu
  /// closes, so it never catches clicks meant for Flutter.
  private func showRoutePicker(for player: ZipAVPlayer, args: [String: Any]) {
    guard let view = registrar.view else { return }
    func number(_ key: String) -> CGFloat {
      CGFloat((args[key] as? NSNumber)?.doubleValue ?? 0)
    }
    let width = max(number("width"), 1)
    let height = max(number("height"), 1)
    let x = number("x")
    let top = number("y")
    let y = view.isFlipped ? top : view.bounds.height - top - height

    let picker: AVRoutePickerView
    if let existing = routePicker {
      picker = existing
    } else {
      picker = AVRoutePickerView(frame: .zero)
      picker.isRoutePickerButtonBordered = false
      for state in [
        AVRoutePickerView.ButtonState.normal, .normalHighlighted, .active, .activeHighlighted,
      ] {
        picker.setRoutePickerButtonColor(.clear, for: state)
      }
      picker.delegate = self
      routePicker = picker
    }
    picker.player = player.player
    picker.frame = NSRect(x: x, y: y, width: width, height: height)
    if picker.superview !== view { view.addSubview(picker) }
    Self.firstButton(in: picker)?.performClick(nil)
  }

  public func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    routePickerView.removeFromSuperview()
  }

  private static func firstButton(in view: NSView) -> NSButton? {
    for sub in view.subviews {
      if let button = sub as? NSButton { return button }
      if let button = firstButton(in: sub) { return button }
    }
    return nil
  }
}

/// One AVPlayer and the texture its frames go to.
///
/// Events go to Dart on `ziptop/avplayer/<id>`. Those about the open stream
/// carry its `open` number, so Dart can drop ones from a stream it has since
/// replaced.
final class ZipAVPlayer: NSObject, FlutterTexture, FlutterStreamHandler,
  AVPlayerItemLegibleOutputPushDelegate
{
  let player = AVPlayer()
  private(set) var textureId: Int64 = 0

  private weak var textures: FlutterTextureRegistry?
  private let eventChannel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private let bufferSeconds: Double

  private var token = 0
  private var output: AVPlayerItemVideoOutput?
  private var legibleOutput: AVPlayerItemLegibleOutput?
  private var audibleGroup: AVMediaSelectionGroup?
  private var legibleGroup: AVMediaSelectionGroup?

  private let pixelLock = NSLock()
  private var latest: CVPixelBuffer?
  private var sentFirstFrame = false
  private var lastBitrate: Double = 0

  private var frameTimer: Timer?
  private var timeObserver: Any?
  private var playerObservers: [NSKeyValueObservation] = []
  private var itemObservers: [NSKeyValueObservation] = []
  private var notificationTokens: [NSObjectProtocol] = []

  init(
    id: Int64, textures: FlutterTextureRegistry, messenger: FlutterBinaryMessenger,
    bufferSeconds: Double, allowsAirPlay: Bool
  ) {
    self.textures = textures
    self.bufferSeconds = bufferSeconds
    eventChannel = FlutterEventChannel(name: "ziptop/avplayer/\(id)", binaryMessenger: messenger)
    super.init()

    player.allowsExternalPlayback = allowsAirPlay
    player.automaticallyWaitsToMinimizeStalling = true
    // Captions start off and audio on the stream's default, as with mpv.
    player.appliesMediaSelectionCriteriaAutomatically = false
    textureId = textures.register(self)
    eventChannel.setStreamHandler(self)

    playerObservers = [
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        DispatchQueue.main.async {
          self?.send([
            "event": "buffering",
            "value": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
          ])
        }
      },
      player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) {
        [weak self] player, _ in
        DispatchQueue.main.async {
          self?.send(["event": "external", "value": player.isExternalPlaybackActive], tied: false)
        }
      },
    ]
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      self?.tick(time)
    }
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.pullFrame()
    }
    RunLoop.main.add(timer, forMode: .common)
    frameTimer = timer
  }

  // MARK: Playback

  func open(url: URL, token: Int, userAgent: String?, headers: [String: String], peakBitRate: Double)
  {
    detachItem()
    self.token = token
    var options: [String: Any] = [:]
    // Not public API, but long-standing and what every player uses for
    // headers AVFoundation has no option for. The CDN expects the Referer.
    if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
    if let userAgent = userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = bufferSeconds
    item.preferredPeakBitRate = peakBitRate

    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    item.add(output)
    let legible = AVPlayerItemLegibleOutput()
    // Captions are drawn by Flutter; the texture never shows AVPlayer's own.
    legible.suppressesPlayerRendering = true
    legible.setDelegate(self, queue: .main)
    item.add(legible)
    self.output = output
    legibleOutput = legible
    sentFirstFrame = false
    lastBitrate = 0

    observe(item)
    player.replaceCurrentItem(with: item)
    player.play()
  }

  func stop() {
    detachItem()
    player.replaceCurrentItem(with: nil)
  }

  func setPeakBitRate(_ rate: Double) {
    player.currentItem?.preferredPeakBitRate = rate
  }

  func selectAudio(_ trackId: String?) {
    guard let item = player.currentItem, let group = audibleGroup,
      let option = Self.option(trackId, in: group)
    else { return }
    item.select(option, in: group)
    sendTracks(item)
  }

  func selectCaptions(_ trackId: String?) {
    guard let item = player.currentItem, let group = legibleGroup else { return }
    item.select(Self.option(trackId, in: group), in: group)
    if trackId == nil { send(["event": "caption", "text": ""]) }
    sendTracks(item)
  }

  func dispose() {
    stop()
    frameTimer?.invalidate()
    frameTimer = nil
    if let observer = timeObserver {
      player.removeTimeObserver(observer)
      timeObserver = nil
    }
    playerObservers.forEach { $0.invalidate() }
    playerObservers = []
    textures?.unregisterTexture(textureId)
    eventChannel.setStreamHandler(nil)
    sink = nil
  }

  private static func option(_ trackId: String?, in group: AVMediaSelectionGroup)
    -> AVMediaSelectionOption?
  {
    guard let trackId = trackId, let index = Int(trackId), group.options.indices.contains(index)
    else { return nil }
    return group.options[index]
  }

  private func observe(_ item: AVPlayerItem) {
    let current = token
    itemObservers = [
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async {
          guard let self = self, self.token == current else { return }
          switch item.status {
          case .failed:
            self.send([
              "event": "error",
              "message": item.error?.localizedDescription ?? "Playback failed",
            ])
          case .readyToPlay:
            self.loadTracks(item)
          default:
            break
          }
        }
      },
      item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async {
          guard let self = self, self.token == current else { return }
          self.sendSize(item.presentationSize)
        }
      },
    ]
    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
        [weak self] _ in
        self?.send(["event": "completed"])
      },
      center.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
      ) { [weak self] note in
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        self?.send([
          "event": "error", "message": error?.localizedDescription ?? "Playback stopped",
        ])
      },
      center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) {
        [weak self, weak item] _ in
        guard let entry = item?.errorLog()?.events.last else { return }
        self?.send([
          "event": "error",
          "message": "\(entry.errorStatusCode) \(entry.errorComment ?? "network error")",
        ])
      },
    ]
  }

  private func detachItem() {
    itemObservers.forEach { $0.invalidate() }
    itemObservers = []
    notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    notificationTokens = []
    if let item = player.currentItem {
      if let output = output { item.remove(output) }
      if let legible = legibleOutput { item.remove(legible) }
    }
    output = nil
    legibleOutput = nil
    audibleGroup = nil
    legibleGroup = nil
    pixelLock.lock()
    latest = nil
    pixelLock.unlock()
  }

  private func loadTracks(_ item: AVPlayerItem) {
    let current = token
    let asset = item.asset
    Task { @MainActor [weak self] in
      let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
      let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
      guard let self = self, self.token == current, self.player.currentItem === item else {
        return
      }
      self.audibleGroup = audible
      self.legibleGroup = legible
      if let legible = legible, legible.allowsEmptySelection { item.select(nil, in: legible) }
      self.sendTracks(item)
    }
  }

  private func sendTracks(_ item: AVPlayerItem) {
    func describe(_ group: AVMediaSelectionGroup?) -> [[String: Any]] {
      guard let group = group else { return [] }
      return group.options.enumerated().map { index, option in
        ["id": "\(index)", "title": option.displayName]
      }
    }
    func selected(_ group: AVMediaSelectionGroup?, none: String) -> String {
      guard let group = group,
        let option = item.currentMediaSelection.selectedMediaOption(in: group),
        let index = group.options.firstIndex(of: option)
      else { return none }
      return "\(index)"
    }
    send([
      "event": "tracks",
      "audio": describe(audibleGroup),
      "captions": describe(legibleGroup),
      "audioId": selected(audibleGroup, none: "auto"),
      "captionId": selected(legibleGroup, none: "no"),
    ])
  }

  private func tick(_ time: CMTime) {
    guard let item = player.currentItem else { return }
    if time.isNumeric {
      send(["event": "position", "ms": Int(time.seconds * 1000)])
    }
    if let rate = item.accessLog()?.events.last?.indicatedBitrate, rate > 0, rate != lastBitrate {
      lastBitrate = rate
      send(["event": "bitrate", "value": Int(rate)])
    }
  }

  private func sendSize(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    send(["event": "size", "width": Double(size.width), "height": Double(size.height)])
  }

  // MARK: Frames

  private func pullFrame() {
    guard let output = output else { return }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    pixelLock.lock()
    latest = buffer
    pixelLock.unlock()
    textures?.textureFrameAvailable(textureId)
    if !sentFirstFrame {
      sentFirstFrame = true
      let size = player.currentItem?.presentationSize ?? .zero
      sendSize(
        size.width > 0
          ? size
          : CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
      send(["event": "firstFrame"])
    }
  }

  /// Called by Flutter's raster thread.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelLock.lock()
    defer { pixelLock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: Captions

  func legibleOutput(
    _ output: AVPlayerItemLegibleOutput,
    didOutputAttributedStrings strings: [NSAttributedString],
    nativeSampleBuffers nativeSamples: [Any],
    forItemTime itemTime: CMTime
  ) {
    send(["event": "caption", "text": strings.map { $0.string }.joined(separator: "\n")])
  }

  // MARK: Events

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// On the main thread only.
  private func send(_ event: [String: Any], tied: Bool = true) {
    var event = event
    if tied { event["open"] = token }
    sink?(event)
  }
}
