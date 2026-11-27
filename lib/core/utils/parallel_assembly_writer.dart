import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// A staging writer used only while one serialized download owns assembly.
/// The coordinator still grants each range separately after checking headroom.
/// Only range paths and results, never file contents, cross to the caller.
final class ParallelAssemblyWriter {
  ParallelAssemblyWriter._(
    this._isolate,
    this._inbox,
    this._replies,
    this._commands,
  );

  // A second active assembly retains its existing streaming path rather
  // than creating another worker isolate on resource-constrained devices.
  static bool _leased = false;

  final Isolate _isolate;
  final ReceivePort _inbox;
  final StreamIterator<dynamic> _replies;
  final SendPort _commands;

  bool _stopped = false;

  static Future<ParallelAssemblyWriter?> tryOpen(
    String path,
    int size,
    int bufferBytes,
  ) async {
    if (_leased) return null;
    _leased = true;
    final inbox = ReceivePort();
    final replies = StreamIterator<dynamic>(inbox);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _assemblyWriterMain,
        (inbox.sendPort, path, size, bufferBytes),
        onError: inbox.sendPort,
        onExit: inbox.sendPort,
        debugName: 'parallel-assembly-writer',
      );
      final commands = await _receive(replies) as SendPort;
      return ParallelAssemblyWriter._(isolate, inbox, replies, commands);
    } catch (error) {
      try {
        isolate?.kill(priority: Isolate.immediate);
        inbox.close();
        await replies.cancel();
      } finally {
        _leased = false;
      }
      if (error is _WriterStopped) {
        throw const FileSystemException('Assembly writer failed to start');
      }
      rethrow;
    }
  }

  static Future<Object?> _receive(StreamIterator<dynamic> replies) async {
    if (!await replies.moveNext()) {
      throw const _WriterStopped();
    }
    final reply = replies.current;
    if (reply is (Object?, FileSystemException, StackTrace)) {
      Error.throwWithStackTrace(reply.$2, reply.$3);
    }
    if (reply case (final Object? value, null, null)) return value;
    // Isolate errors (a list of strings) or an early exit (null) must neither
    // hang a serialized parent nor be taken as a successful range write.
    // Wait for the exit notification so cleanup cannot race its output fd.
    if (reply is List) await replies.moveNext();
    throw const _WriterStopped();
  }

  Future<Object?> _request(Object command) async {
    _commands.send(command);
    try {
      return await _receive(_replies);
    } on _WriterStopped {
      _stopped = true;
      throw const FileSystemException('Assembly writer stopped before reply');
    }
  }

  Future<bool> copy(String path, int bytes) async =>
      await _request((path, bytes)) as bool;

  Future<void> flush() async {
    await _request(true);
  }

  Future<void> close() async {
    try {
      if (!_stopped) await _request(false);
    } finally {
      try {
        _inbox.close();
        await _replies.cancel();
      } finally {
        _isolate.kill(priority: Isolate.immediate);
        _leased = false;
      }
    }
  }
}

class _WriterStopped implements Exception {
  const _WriterStopped();
}

Future<void> _assemblyWriterMain(
  (SendPort replies, String path, int size, int bufferBytes) startup,
) async {
  final (replies, path, size, bufferBytes) = startup;
  final commands = ReceivePort();
  RandomAccessFile? output;
  try {
    try {
      output = File(path).openSync(mode: FileMode.write);
      output.truncateSync(size);
      output.setPositionSync(0);
    } on FileSystemException catch (error, stack) {
      try {
        output?.closeSync();
      } finally {
        output = null;
        replies.send((null, error, stack));
      }
      return;
    }
    final buffer = Uint8List(bufferBytes);
    var remainingAssemblyBytes = size;
    replies.send((commands.sendPort, null, null));
    await for (final command in commands) {
      try {
        if (command == false) {
          output!.closeSync();
          output = null;
          replies.send((null, null, null));
          break;
        }
        if (command == true) {
          output!.flushSync();
          replies.send((null, null, null));
          continue;
        }
        final (sourcePath, bytes) = command as (String, int);
        final input = File(sourcePath).openSync();
        var remainingPartBytes = bytes;
        var oversized = false;
        try {
          while (true) {
            final length = input.readIntoSync(buffer);
            if (length == 0) break;
            if (length > remainingPartBytes ||
                length > remainingAssemblyBytes) {
              oversized = true;
              break;
            }
            output!.writeFromSync(buffer, 0, length);
            remainingPartBytes -= length;
            remainingAssemblyBytes -= length;
          }
        } finally {
          input.closeSync();
        }
        replies.send((remainingPartBytes == 0 && !oversized, null, null));
      } on FileSystemException catch (error, stack) {
        replies.send((null, error, stack));
      }
    }
  } finally {
    commands.close();
    output?.closeSync();
  }
}
