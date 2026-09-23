/// Drag files out of a Flutter desktop app into Finder/Explorer.
///
/// Keep using Flutter's own `Draggable` for in-app drags. When the pointer
/// leaves the window during such a drag, [FlutterDragOut.maybeStartOnExit]
/// hands the drag over to a real OS drag session carrying the given file
/// paths, so the user can drop them into another application.
///
/// The plugin only *starts* drag sessions. It never registers a drop target,
/// so it coexists with drag-in packages such as `desktop_drop` and with
/// Flutter's `Draggable`/`DragTarget`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Entry point of the plugin. All members are static.
abstract final class FlutterDragOut {
  static const _channel = MethodChannel('flutter_drag_out');

  static bool _handlerInstalled = false;
  static bool _inProgress = false;

  /// Whether this platform has a native implementation.
  ///
  /// On other platforms every call is a no-op that returns `false`.
  static bool get isSupported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// Whether a drag session started by this plugin is still running.
  ///
  /// Useful to ignore the app's own files if the user drags them back into
  /// the window and a drag-in handler (e.g. `desktop_drop`) reports them.
  static bool get inProgress => _inProgress;

  /// Starts an OS drag session carrying [paths] (absolute local paths of files
  /// and/or directories).
  ///
  /// Must be called while the left mouse button is held down, i.e. from a
  /// drag update. Only the copy operation is offered to other applications,
  /// and drops back into this app are rejected. As soon as the session
  /// starts, the plugin sends Flutter a synthetic mouse-up so the Flutter
  /// drag that triggered it ends (it is cancelled, since the pointer is
  /// outside the window).
  ///
  /// Returns `true` if the session started.
  static Future<bool> start(List<String> paths) async {
    if (!isSupported || _inProgress || paths.isEmpty) return false;
    _installHandler();
    _inProgress = true;
    try {
      final started = await _channel.invokeMethod<bool>('startDrag', paths) ?? false;
      if (!started) _inProgress = false;
      return started;
    } on PlatformException {
      _inProgress = false;
      return false;
    } on MissingPluginException {
      _inProgress = false;
      return false;
    }
  }

  /// Call from `Draggable.onDragUpdate`. Starts a native drag session once
  /// [globalPosition] leaves the window (`Offset.zero & viewSize`, where
  /// [viewSize] is typically `MediaQuery.sizeOf(context)`).
  ///
  /// [paths] is only evaluated when the pointer is outside; return `null` or
  /// an empty list to keep the drag inside the app (for example when the
  /// dragged items have no local path).
  ///
  /// ```dart
  /// Draggable<MyPayload>(
  ///   onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
  ///     details.globalPosition,
  ///     viewSize: MediaQuery.sizeOf(context),
  ///     paths: () => selectedFiles.map((f) => f.path).toList(),
  ///   ),
  ///   ...
  /// )
  /// ```
  static void maybeStartOnExit(
    Offset globalPosition, {
    required Size viewSize,
    required List<String>? Function() paths,
  }) {
    if (!isSupported || _inProgress) return;
    if ((Offset.zero & viewSize).contains(globalPosition)) return;
    final list = paths();
    if (list == null || list.isEmpty) return;
    start(list);
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'dragEnded') _inProgress = false;
    });
  }

  /// Resets internal state. For tests only.
  @visibleForTesting
  static void debugReset() {
    _inProgress = false;
    _handlerInstalled = false;
  }
}
