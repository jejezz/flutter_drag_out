# flutter_drag_out

Drag files out of a Flutter desktop app into Finder / Explorer.

Flutter's `Draggable` only lives inside the app window, so the OS never sees
it. This plugin keeps `Draggable` for everything inside the app and, **only
when the pointer leaves the window**, hands the drag over to a real OS drag
session carrying file paths.

It only *starts* drag sessions and never registers a drop target, so it
coexists with Flutter's `Draggable`/`DragTarget` and with drag-in packages
such as [`desktop_drop`](https://pub.dev/packages/desktop_drop). Adopting it
is one line in an existing `Draggable`.

| Platform | Status |
|---|---|
| macOS | ✅ (10.15+) |
| Windows | planned |
| Linux | planned |

On unsupported platforms every call is a no-op, so the drag simply stays
inside the app.

## Install

```yaml
dependencies:
  flutter_drag_out:
    git:
      url: https://github.com/jejezz/flutter_drag_out.git
      ref: v0.1.0
```

## Usage

```dart
import 'package:flutter_drag_out/flutter_drag_out.dart';

Draggable<MyPayload>(
  data: payload,
  onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
    details.globalPosition,
    viewSize: MediaQuery.sizeOf(context),
    // Evaluated only once the pointer is outside the window.
    // Return null/empty to keep the drag inside the app
    // (e.g. for remote items that have no local path).
    paths: () => payload.files.map((f) => f.path).toList(),
  ),
  feedback: ...,
  child: ...,
)
```

If you also accept drops from other apps (e.g. with `desktop_drop`), you can
ignore the app's own files coming back:

```dart
onDragDone: (details) {
  if (FlutterDragOut.inProgress) return;
  ...
}
```

## Behavior

- Paths must be absolute local paths (files and/or directories). Mounted
  network drives are fine — they are local paths to the OS.
- Only **copy** is offered to other applications, so e.g. Finder never moves
  the originals behind the app's back.
- Drops back into the same app are rejected; in-app moves belong to your
  Flutter `Draggable`/`DragTarget`.
- Once the pointer has left the window the drag belongs to the OS. Coming back
  and dropping on the app does nothing.
- When the OS session starts, the plugin synthesizes the mouse-up that the OS
  drag loop swallows, so the Flutter drag that triggered it ends (cancelled —
  nothing accepts it outside the window) instead of getting stuck.
- Sandboxed macOS apps can drag any file they can read.

## Example

See [`example/`](example/lib/main.dart): a list of sample files that can be
dropped on an in-app target or dragged out to Finder, alone or several at once.

## License

MIT
