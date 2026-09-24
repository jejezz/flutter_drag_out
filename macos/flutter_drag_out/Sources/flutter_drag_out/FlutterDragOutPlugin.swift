import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// One item of a drag session, as sent by Dart.
private enum DragItem {
  /// A file or directory that already exists.
  case path(String)
  /// A file or directory Dart writes after the drop (a file promise).
  case promise(id: Int, name: String, isDirectory: Bool)
}

/// What a promise provider needs to ask Dart to write its item.
private final class PromiseInfo {
  init(session: Any, id: Int, name: String) {
    self.session = session
    self.id = id
    self.name = name
  }

  let session: Any
  let id: Int
  let name: String
}

/// Starts native OS drag sessions carrying file URLs or file promises so
/// files can be dragged out of the Flutter app into Finder and other
/// applications.
///
/// It never registers a drop target: in-app drags stay with Flutter's own
/// `Draggable`, and drag-in stays with whatever the app already uses.
public class FlutterDragOutPlugin: NSObject, FlutterPlugin, NSDraggingSource,
  NSFilePromiseProviderDelegate
{
  private let registrar: FlutterPluginRegistrar
  private let channel: FlutterMethodChannel
  private var lastMouseEvent: NSEvent?
  private var monitor: Any?
  /// Dart's ID of the running session, echoed back in `dragEnded`. `nil`
  /// while no session runs or when started with the pre-0.4.0 arguments.
  private var session: Any?
  /// Where AppKit asks promise providers to write; each request is handed to
  /// Dart on the main queue.
  private let promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()

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
      guard let (session, items) = Self.parseStartDrag(call.arguments) else {
        result(FlutterError(code: "bad_args", message: "Expected {session, items}", details: nil))
        return
      }
      // Set first: endedAt must find it even if AppKit ended the session
      // right away.
      self.session = session
      let started = startDrag(items: items, session: session)
      if !started { self.session = nil }
      result(started)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Accepts `{session, items: [{type: "path", path} | {type: "promise", id,
  /// name, directory}]}`, or the pre-0.4.0 bare list of paths. Returns `nil`
  /// for anything else, including item types this version does not know, and
  /// promises without a session (their writes are addressed by session).
  private static func parseStartDrag(_ arguments: Any?) -> (session: Any?, items: [DragItem])? {
    if let paths = arguments as? [String] { return (nil, paths.map(DragItem.path)) }
    guard let map = arguments as? [String: Any],
      let rawItems = map["items"] as? [[String: Any]]
    else { return nil }
    let session = map["session"].flatMap { $0 is NSNull ? nil : $0 }
    var items: [DragItem] = []
    for item in rawItems {
      switch item["type"] as? String {
      case "path":
        guard let path = item["path"] as? String else { return nil }
        items.append(.path(path))
      case "promise":
        guard session != nil,
          let id = item["id"] as? Int,
          let name = item["name"] as? String,
          !name.isEmpty
        else { return nil }
        items.append(.promise(id: id, name: name, isDirectory: item["directory"] as? Bool ?? false))
      default:
        return nil
      }
    }
    return (session, items)
  }

  private func startDrag(items dragItems: [DragItem], session: Any?) -> Bool {
    guard !dragItems.isEmpty,
      let view = registrar.view,
      let event = lastMouseEvent,
      event.type == .leftMouseDragged,
      event.window === view.window
    else { return false }

    let location = view.convert(event.locationInWindow, from: nil)
    let iconSize: CGFloat = 48
    let items = dragItems.enumerated().map { index, dragItem -> NSDraggingItem in
      let writer: NSPasteboardWriting
      let icon: NSImage
      switch dragItem {
      case .path(let path):
        writer = NSURL(fileURLWithPath: path)
        icon = NSWorkspace.shared.icon(forFile: path)
      case .promise(let id, let name, let isDirectory):
        let fileType = Self.typeIdentifier(name: name, isDirectory: isDirectory)
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = PromiseInfo(session: session!, id: id, name: name)
        writer = provider
        icon = Self.icon(forTypeIdentifier: fileType)
      }
      let item = NSDraggingItem(pasteboardWriter: writer)
      // Several items are drawn as a slightly offset stack.
      let offset = CGFloat(min(index, 4)) * 6
      item.setDraggingFrame(
        NSRect(
          x: location.x - iconSize / 2 + offset,
          y: location.y - iconSize / 2 + offset,
          width: iconSize,
          height: iconSize
        ),
        contents: icon
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

  /// The type Finder shows for a promised item: a folder, the type of the
  /// name's extension, or plain data.
  private static func typeIdentifier(name: String, isDirectory: Bool) -> String {
    if isDirectory { return "public.folder" }
    let ext = (name as NSString).pathExtension
    if #available(macOS 11.0, *) {
      return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    }
    let tag = UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassFilenameExtension, ext as CFString, nil)
    return tag?.takeRetainedValue() as String? ?? "public.data"
  }

  private static func icon(forTypeIdentifier identifier: String) -> NSImage {
    if #available(macOS 11.0, *), let type = UTType(identifier) {
      return NSWorkspace.shared.icon(for: type)
    }
    return NSWorkspace.shared.icon(forFileType: identifier)
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
    let session = self.session
    self.session = nil
    channel.invokeMethod(
      "dragEnded",
      arguments: ["session": session ?? NSNull(), "dropped": operation != []] as [String: Any]
    )
  }

  // MARK: - NSFilePromiseProviderDelegate

  public func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    (filePromiseProvider.userInfo as? PromiseInfo)?.name ?? "Untitled"
  }

  /// Asks Dart to write the promised item at [url] (the drop destination plus
  /// the item's name) and tells AppKit how it went.
  public func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
      completionHandler(Self.writeError("Unknown promised item"))
      return
    }
    let arguments: [String: Any] = [
      "session": info.session, "id": info.id, "targetPath": url.path, "final": true,
    ]
    // Channel messages must be sent from the main thread.
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("writePromise", arguments: arguments) { result in
        if let error = result as? FlutterError {
          completionHandler(Self.writeError(error.message ?? error.code))
        } else if (result as AnyObject?) === FlutterMethodNotImplemented {
          completionHandler(Self.writeError("writePromise is not handled"))
        } else {
          completionHandler(nil)
        }
      }
    }
  }

  public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
    promiseQueue
  }

  private static func writeError(_ message: String) -> NSError {
    NSError(
      domain: "flutter_drag_out", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
