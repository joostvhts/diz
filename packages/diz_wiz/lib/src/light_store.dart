import 'dart:io';

/// Where a [Registry] keeps what it knows about the lights between runs:
/// names, addresses and models. Live state is always re-read from the bulbs.
///
/// The bridge saves to a file ([FileLightStore]); the app can keep the same
/// JSON in its own settings.
abstract interface class LightStore {
  /// The saved JSON, or null when nothing has been saved yet.
  Future<String?> read();

  /// Replaces the saved JSON.
  Future<void> write(String json);
}

/// Saves to a JSON file. Writes go to a temporary file first and are then
/// renamed, so a crash mid-write never leaves a half-written file.
class FileLightStore implements LightStore {
  FileLightStore(this.path);

  final String path;

  @override
  Future<String?> read() async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String json) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(json);
    await tmp.rename(path);
  }

  @override
  String toString() => path;
}

/// Keeps the JSON in memory only. For tests.
class MemoryLightStore implements LightStore {
  MemoryLightStore([this.json]);

  String? json;

  @override
  Future<String?> read() async => json;

  @override
  Future<void> write(String json) async => this.json = json;

  @override
  String toString() => 'memory';
}
