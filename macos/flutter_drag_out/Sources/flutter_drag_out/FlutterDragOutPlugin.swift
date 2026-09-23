import Cocoa
import FlutterMacOS

/// Starts native OS drag sessions carrying file URLs so files can be dragged
/// out of the Flutter app into Finder and other applications.
///
/// It never registers a drop target: in-app drags stay with Flutter's own
/// `Draggable`, and drag-in stays with whatever the app already uses.
public class FlutterDragOutPlugin: NSObject, FlutterPlugin, NSDraggingSource {
  private let registrar: FlutterPluginRegistrar
  private let channel: FlutterMethodChannel
  private var lastMouseEvent: NSEvent?
  private var monitor: Any?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_drag_out", binaryMessenger: registrar.messenger)
    let instance = FlutterDragOutPlugin(registrar: registrar, channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
    self.registrar = registrar
    self.channel = channel
    super.init()

    // beginDraggingSession needs a mouse event, but while a channel message is
    // being handled NSApp.currentEvent is not one. Remember the latest
    // press/drag event instead.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) {
      [weak self] event in
      self?.lastMouseEvent = event
      return event
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startDrag":
      guard let paths = call.arguments as? [String] else {
        result(FlutterError(code: "bad_args", message: "Expected a list of paths", details: nil))
        return
      }
      result(startDrag(paths: paths))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startDrag(paths: [String]) -> Bool {
    guard !paths.isEmpty,
      let view = registrar.view,
      let event = lastMouseEvent,
      event.type == .leftMouseDragged,
      event.window === view.window
    else { return false }

    let location = view.convert(event.locationInWindow, from: nil)
    let iconSize: CGFloat = 48
    let items = paths.enumerated().map { index, path -> NSDraggingItem in
      let item = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: path))
      // Several items are drawn as a slightly offset stack.
      let offset = CGFloat(min(index, 4)) * 6
      item.setDraggingFrame(
        NSRect(
          x: location.x - iconSize / 2 + offset,
          y: location.y - iconSize / 2 + offset,
          width: iconSize,
          height: iconSize
        ),
        contents: NSWorkspace.shared.icon(forFile: path)
      )
      return item
    }

    let session = view.beginDraggingSession(with: items, event: event, source: self)
    // The "starting position" is a row Flutter drew, which AppKit knows
    // nothing about, so don't animate back to it on cancel.
    session.animatesToStartingPositionsOnCancelOrFail = false

    // From now on AppKit's drag loop consumes the mouse-up, so Flutter never
    // sees it and would consider the button held forever. Synthesize one right
    // away at the (outside-the-window) pointer location: no DragTarget is
    // there, so the Flutter drag that triggered this is simply cancelled.
    if let up = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: event.locationInWindow,
      modifierFlags: event.modifierFlags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: event.windowNumber,
      context: nil,
      eventNumber: event.eventNumber,
      clickCount: 1,
      pressure: 0
    ) {
      flutterViewController(of: view)?.mouseUp(with: up)
    }
    return true
  }

  /// Mouse events are handled by the FlutterViewController, which sits above
  /// the FlutterView in the responder chain.
  private func flutterViewController(of view: NSView) -> NSResponder? {
    var responder: NSResponder? = view
    while let current = responder {
      if current is FlutterViewController { return current }
      responder = current.nextResponder
    }
    return nil
  }

  // Copy only when dropped into another application — allowing move would let
  // e.g. Finder relocate the original behind the app's back. Drops back into
  // this app are rejected: in-app moves belong to Flutter's own drag.
  public func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? .copy : []
  }

  public func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    channel.invokeMethod("dragEnded", arguments: operation != [])
  }
}
