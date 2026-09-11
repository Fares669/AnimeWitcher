from pathlib import Path

path = Path('lib/core/services/persistent_parallel_download.dart')
text = path.read_text()

old_pump = '''        Future<void>.microtask(() async {
                    final sessions = List<_ParallelSession>.from(_sessions.values);
                    for (final session in sessions) {
                      if (_disposed) return;
                      if (!session.active || session.deleted) continue;
                      await session.serialize(() async {
                        if (_disposed || !session.active || session.deleted) return;
                        try {
                          if (!await _pumpSession(session)) {
                            _scheduleCoordinatorRecovery(session);
                          } else {
                            await _persist(session);
                          }
                        } catch (_) {
                          // Coordinator bookkeeping is not a user-visible pause.
                          // Keep native owners untouched and reconcile them shortly.
                          _scheduleCoordinatorRecovery(session);
                        }
                      });
                    }
                  })'''
new_pump = '''        Future<void>.microtask(() async {
                    final sessions = List<_ParallelSession>.from(_sessions.values);
                    await Future.wait<void>(
                      sessions
                          .where((session) => session.active && !session.deleted)
                          .map(
                            (session) => session.serialize(() async {
                              if (_disposed ||
                                  !session.active ||
                                  session.deleted) {
                                return;
                              }
                              try {
                                if (!await _pumpSession(session)) {
                                  _scheduleCoordinatorRecovery(session);
                                } else {
                                  await _persist(session);
                                }
                              } catch (_) {
                                // One slow/failing session must not head-of-line block
                                // unrelated sessions. Per-session serialization still
                                // preserves ordering inside each logical download.
                                _scheduleCoordinatorRecovery(session);
                              }
                            }),
                          ),
                    );
                  })'''
if text.count(old_pump) != 1:
    raise SystemExit(f'DM-13 pump anchor count={text.count(old_pump)}')
text = text.replace(old_pump, new_pump, 1)

old_reservation = '''        _preparePartAttempt(session, part);
        await _persist(session);

        // Reserve before enqueueing to close the enqueue->running race. This'''
new_reservation = '''        _preparePartAttempt(session, part);
        await _persist(session);

        // Parallel session pumps can consume capacity while this pump awaits
        // record/manifest IO. Revalidate immediately before the synchronous
        // reservation so stale availability can never overbook the global or
        // per-session connection budget.
        if (_activeConnectionIds.length >= _connectionBudget ||
            _activeConnectionsForSession(session) >= session.connectionCeiling) {
          return true;
        }

        // Reserve before enqueueing to close the enqueue->running race. This'''
if text.count(old_reservation) != 1:
    raise SystemExit(
        f'DM-13 reservation anchor count={text.count(old_reservation)}'
    )
text = text.replace(old_reservation, new_reservation, 1)
path.write_text(text)
