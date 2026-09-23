# flutter_drag_out

Drag files and folders out of a Flutter desktop app into Finder, Explorer or
any other application — without replacing Flutter's own drag and drop.

Flutter's `Draggable` only exists inside the app window; the operating system
never sees it, so you cannot drop it into another app. `flutter_drag_out`
keeps `Draggable` in charge of everything inside your app and, **only at the
moment the pointer leaves the window**, hands the drag over to a real OS drag
session carrying file paths.

```
 inside the window                    outside the window
┌──────────────────────────┐
│  Flutter Draggable        │  pointer   ┌──────────────────────────┐
│  (your DragTargets work   │ ─ leaves ─▶│  native OS drag session   │ ─▶ Finder / Explorer
│   exactly as before)      │  window    │  (file URLs, copy only)   │
└──────────────────────────┘            └──────────────────────────┘
```

## Features

- **One line to adopt.** Add a call to an existing `Draggable.onDragUpdate`;
  no widget replacement, no changes to your `DragTarget`s.
- **Coexists with drag-in packages.** The plugin only *starts* drag sessions
  and never registers a drop target, so it works alongside
  [`desktop_drop`](https://pub.dev/packages/desktop_drop) or any other
  drag-in handler.
- **Files and folders, one or many.** Pass any number of absolute paths.
- **Safe by default.** Only *copy* is offered to other applications, so they
  never move your files behind the app's back. Drops back into your own app
  are rejected.
- **No stuck drags.** The OS drag loop swallows the mouse-up; the plugin
  synthesizes one so the Flutter drag ends cleanly.
- **Graceful fallback.** On platforms without an implementation every call is
  a no-op and the drag simply stays inside the app.

## Platform support

| Platform | Status | Native API |
|---|---|---|
| macOS 10.15+ | ✅ Supported | `NSDraggingSession` |
| Windows 10+ | ✅ Supported | OLE `DoDragDrop` (`CF_HDROP`) |
| Linux (GTK 3) | ✅ Supported | `gtk_drag_begin` (`text/uri-list`) |

## Installation

The package is not on pub.dev yet. Add it as a git dependency pinned to a tag:

```yaml
dependencies:
  flutter_drag_out:
    git:
      url: https://github.com/jejezz/flutter_drag_out.git
      ref: v0.3.0
```

No native setup is required; the plugin registers itself.

## Usage

Call `FlutterDragOut.maybeStartOnExit` from the `onDragUpdate` of the
`Draggable` you already have:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_drag_out/flutter_drag_out.dart';

class FileRow extends StatelessWidget {
  const FileRow({super.key, required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    return Draggable<File>(
      data: file,
      onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
        details.globalPosition,
        viewSize: viewSize,
        paths: () => [file.path],
      ),
      feedback: Material(child: Text(file.path)),
      child: ListTile(title: Text(file.path)),
    );
  }
}
```

`paths` is evaluated only once the pointer is outside the window. Return
`null` or an empty list to keep the drag inside the app — for example when
the dragged items are remote and have no local path:

```dart
paths: () => items.every((i) => i.isLocal)
    ? items.map((i) => i.path).toList()
    : null, // stays an in-app drag
```

### Ignoring your own files on drag-in

Once a drag has left the window it belongs to the OS. If the user brings it
back, the plugin rejects the drop, but a drag-in handler may still be told
about it. Use `inProgress` to ignore it:

```dart
DropTarget( // from desktop_drop
  onDragDone: (details) {
    if (FlutterDragOut.inProgress) return;
    importFiles(details.files);
  },
  child: ...,
)
```

### Starting a session yourself

`maybeStartOnExit` is a convenience wrapper. To decide the moment yourself,
call `start` while the left mouse button is held down (e.g. from a drag
update):

```dart
final started = await FlutterDragOut.start(['/Users/me/report.pdf']);
```

## API

| Member | Description |
|---|---|
| `FlutterDragOut.maybeStartOnExit(globalPosition, viewSize:, paths:)` | Starts a session once `globalPosition` is outside `Offset.zero & viewSize`. Does nothing while a session is running. |
| `FlutterDragOut.start(List<String> paths)` → `Future<bool>` | Starts a session with the given absolute paths. Returns `false` if unsupported, already running, or the native side could not start. |
| `FlutterDragOut.inProgress` | `true` while a session started by this plugin is running. |
| `FlutterDragOut.isSupported` | `true` on platforms with a native implementation. |

## How it works

1. The user drags with your Flutter `Draggable` as usual.
2. When `onDragUpdate` reports a position outside the window, the plugin asks
   the native side to start an OS drag session with the file paths. This
   works because Flutter keeps receiving pointer moves outside the window
   while the button is held (macOS delivers them to the window; on Windows the
   Flutter embedder captures the mouse on button down; on Linux GTK keeps an
   implicit grab). On macOS the session
   reuses the latest mouse-dragged event, since the OS requires one; on
   Windows the modal `DoDragDrop` loop is started from a posted message, not
   from inside the method call; on Linux the drag also reuses the latest
   motion event (Wayland requires its serial).
3. The OS drag loop now owns the mouse, so Flutter would never receive the
   mouse-up. The plugin immediately synthesizes one at the pointer position
   outside the window. Nothing accepts the drop there, so your Flutter drag
   is cancelled cleanly.
4. The OS offers *copy* to other applications and rejects drops back into
   your app. When the session ends, `inProgress` goes back to `false`.

## Limitations

- **Local paths only.** Paths must exist on the local file system (mounted
  network drives count). Files that must be downloaded first, such as items
  on FTP or WebDAV, are not supported — copy them locally first.
- **One-way hand-over.** After the pointer leaves the window the drag cannot
  return to your in-app `DragTarget`s.
- **Copy only.** Moving files to another application is intentionally not
  offered.
- **macOS sandbox.** Sandboxed apps can drag any file they are able to read.
- **Windows modal loop.** `DoDragDrop` runs a modal loop on the platform
  thread until the drop; the app keeps processing messages but stays in that
  loop for the duration of the drag.

## Example

The [`example/`](example/lib/main.dart) app lists a few sample files. Drop them
on the in-app target, or drag them out to Finder / Explorer / your file manager — alone or several at once
(tick the checkboxes).

```sh
cd example
flutter run -d macos    # or: -d windows, -d linux
```

## Why not `super_drag_and_drop`?

[`super_drag_and_drop`](https://pub.dev/packages/super_drag_and_drop) is a
full drag-and-drop framework: it replaces both your in-app drag and your drop
handling with its own native pipeline. That is powerful, but adopting it means
migrating all existing drag code at once. `flutter_drag_out` does one thing —
start an outbound drag session — so it can be added to an app whose drag and
drop already works, without touching it.

## License

[MIT](LICENSE)
