import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background_downloader 9.6 transfer API contract compiles', () {
    expect(_transferApiContract, isA<Function>());
  });
}

void _transferApiContract(Transfers transfers, Task task, Transfer transfer) {
  final Future<Transfer> start = transfers.start(task);
  final Future<Transfer> getOrStart = transfers.getOrStart(
    task,
    matchBy: (existingTask) => existingTask.taskId == task.taskId,
    reEnqueueIfFailed: false,
  );
  final Future<List<Transfer>> rehydrate = transfers.rehydrateFromDatabase();
  final Future<bool> pause = transfer.pause();
  final Future<bool> resume = transfer.resume();
  final Future<bool> cancel = transfer.cancel();

  // Keep the typed references live so the compiler verifies every API surface.
  Object.hash(start, getOrStart, rehydrate, pause, resume, cancel);
}
