import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transport exposes one global stream for Transfer API updates', () {
    final source = File(
      'lib/core/services/background_downloader_transport.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('final StreamController<TaskUpdate> _updates ='),
    );
    expect(source, contains('Stream<TaskUpdate> get updates => _updates.stream;'));

    final attachStart = source.indexOf('void _attach(Transfer transfer) {');
    final attachEnd = source.indexOf('void _detach(String taskId)', attachStart);
    expect(attachStart, greaterThanOrEqualTo(0));
    expect(attachEnd, greaterThan(attachStart));
    final attach = source.substring(attachStart, attachEnd);
    expect(attach, contains('if (!_updates.isClosed) _updates.add(update);'));

    final disposeStart = source.indexOf('Future<void> dispose() async {');
    expect(disposeStart, greaterThanOrEqualTo(0));
    final dispose = source.substring(disposeStart);
    expect(dispose, contains('await _updates.close();'));
  });

  test('service bridges Transfer updates before plugin start and rehydrate', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    expect(
      source,
      contains('StreamSubscription<TaskUpdate>? _nativeUpdatesSubscription;'),
    );

    final initializeStart = source.indexOf('Future<void> _initialize() async {');
    final initializeEnd = source.indexOf(
      'Future<void> _startPluginExecutor() async {',
      initializeStart,
    );
    expect(initializeStart, greaterThanOrEqualTo(0));
    expect(initializeEnd, greaterThan(initializeStart));
    final initialize = source.substring(initializeStart, initializeEnd);

    final bridge = initialize.indexOf(
      '_nativeUpdatesSubscription = _nativeTransport.updates.listen(_sharedEvents.add);',
    );
    final pluginStart = initialize.indexOf('await _startPluginExecutor();');
    expect(bridge, greaterThanOrEqualTo(0));
    expect(pluginStart, greaterThan(bridge));

    final disposeStart = source.indexOf('Future<void> _disposeResources() async {');
    final disposeEnd = source.indexOf('bool _hasConnectivity(', disposeStart);
    expect(disposeStart, greaterThanOrEqualTo(0));
    expect(disposeEnd, greaterThan(disposeStart));
    final dispose = source.substring(disposeStart, disposeEnd);
    expect(dispose, contains('await _nativeUpdatesSubscription?.cancel();'));
    expect(dispose, contains('_nativeUpdatesSubscription = null;'));
  });
}
