import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_drag_out/flutter_drag_out.dart';

void main() => runApp(const MaterialApp(home: ExamplePage()));

/// Drag any row inside the window to drop it on the in-app target, or drag it
/// out of the window to drop it into Finder. Tick several rows to drag them
/// together.
class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  List<FileSystemEntity> _entries = const [];
  final Set<String> _selected = {};
  String _status = 'Drag a row out of the window.';

  @override
  void initState() {
    super.initState();
    _createSampleFiles();
  }

  Future<void> _createSampleFiles() async {
    final dir = await Directory.systemTemp.createTemp('flutter_drag_out_example');
    await File('${dir.path}/hello.txt').writeAsString('Hello from flutter_drag_out\n');
    await File('${dir.path}/notes.md').writeAsString('# Notes\n');
    final folder = await Directory('${dir.path}/folder').create();
    await File('${folder.path}/inside.txt').writeAsString('inside a folder\n');
    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    setState(() => _entries = entries);
  }

  List<String> _pathsFor(FileSystemEntity entity) =>
      _selected.contains(entity.path) ? _selected.toList() : [entity.path];

  String _name(String path) => path.split(Platform.pathSeparator).last;

  /// Items that don't exist until they are dropped (file promises, macOS).
  late final List<(IconData, DragOutPromise)> _promises = [
    (
      Icons.note_add,
      DragOutPromise(
        name: 'generated.txt',
        write: (request) async {
          await File(request.targetPath).writeAsString('Created on drop at ${DateTime.now()}\n');
          _report('Wrote ${request.targetPath}');
        },
      ),
    ),
    (
      Icons.create_new_folder,
      DragOutPromise(
        name: 'generated folder',
        isDirectory: true,
        write: (request) async {
          final dir = await Directory(request.targetPath).create();
          for (var i = 1; i <= 3; i++) {
            await File('${dir.path}/file $i.txt').writeAsString('File $i\n');
          }
          _report('Wrote ${request.targetPath}');
        },
      ),
    ),
    (
      Icons.hourglass_bottom,
      DragOutPromise(
        name: 'slow.txt',
        write: (request) async {
          _report('Writing slow.txt (3 s)...');
          for (var i = 0; i < 30; i++) {
            if (request.isCancelled) throw StateError('cancelled');
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await File(request.targetPath).writeAsString('Took a while\n');
          _report('Wrote ${request.targetPath}');
        },
      ),
    ),
  ];

  void _report(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_drag_out example')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final entity in _entries)
                  Draggable<List<String>>(
                    data: _pathsFor(entity),
                    onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
                      details.globalPosition,
                      viewSize: viewSize,
                      paths: () => _pathsFor(entity),
                      onEnded: (end) => setState(
                        () => _status = end.dropped
                            ? 'Dropped outside the app: ${_pathsFor(entity).map(_name).join(', ')}'
                            : 'Drag out cancelled.',
                      ),
                    ),
                    feedback: Material(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_pathsFor(entity).map(_name).join(', ')),
                      ),
                    ),
                    child: CheckboxListTile(
                      value: _selected.contains(entity.path),
                      onChanged: (checked) => setState(() {
                        checked == true
                            ? _selected.add(entity.path)
                            : _selected.remove(entity.path);
                      }),
                      secondary: Icon(
                        entity is Directory ? Icons.folder : Icons.description,
                      ),
                      title: Text(_name(entity.path)),
                    ),
                  ),
                if (FlutterDragOut.supportsPromises) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Created only when dropped (file promises):'),
                  ),
                  for (final (icon, promise) in _promises)
                    Draggable<String>(
                      data: promise.name,
                      onDragUpdate: (details) => FlutterDragOut.maybeStartOnExit(
                        details.globalPosition,
                        viewSize: viewSize,
                        items: () => [promise],
                        onEnded: (end) => _report(end.dropped ? 'Dropped ${promise.name}' : 'Drag out cancelled.'),
                      ),
                      feedback: Material(
                        elevation: 4,
                        child: Padding(padding: const EdgeInsets.all(8), child: Text(promise.name)),
                      ),
                      child: ListTile(leading: Icon(icon), title: Text(promise.name)),
                    ),
                ],
              ],
            ),
          ),
          DragTarget<List<String>>(
            onAcceptWithDetails: (details) => setState(
              () => _status = 'Dropped inside the app: ${details.data.map(_name).join(', ')}',
            ),
            builder: (context, candidates, _) => Container(
              height: 120,
              width: double.infinity,
              alignment: Alignment.center,
              color: candidates.isEmpty ? Colors.blueGrey.shade50 : Colors.blue.shade100,
              child: Text('In-app drop target\n$_status', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}
