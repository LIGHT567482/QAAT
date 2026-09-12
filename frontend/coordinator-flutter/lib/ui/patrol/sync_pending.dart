import '../../patrol/fingerprint.dart';
import '../../patrol/patrol_client.dart';
import '../../patrol/patrol_store.dart';

/// Push every queued lecture observation. Returns the message to show, or null
/// when all is well. A port of the native `syncPending`.
///
/// Both rounds drain BOTH queues — a queue that only empties from the screen that
/// filled it is a queue that loses data: a monitor who walks offices on Monday and
/// opens only the room round on Tuesday would carry Monday's visits until they
/// happened to return to the right tab — or lose them with the handset.
///
/// A generic network failure returns null (the batch stays queued and retries);
/// only a handset rejection surfaces a message, because that is the one failure
/// the monitor must be told about now.
Future<String?> syncPending(String token) async {
  if (token.isEmpty) return null;
  final store = patrolStore;
  final pending = await store.unsyncedPatrolLogs();
  if (pending.isEmpty) return null;
  try {
    final ok = await PatrolClient()
        .sync(token, await DeviceFingerprint.get(), pending);
    if (ok) {
      for (final l in pending) {
        await store.markPatrolLogSynced(l.id);
      }
    }
    return ok ? null : 'The server did not accept the round — it stays saved and will retry.';
  } on PatrolDeviceRejected catch (e) {
    return e.message;
  } on Object {
    return null;
  }
}

/// Push every queued OFFICE visit. Same shape as [syncPending].
Future<String?> syncPendingOffice(String token) async {
  if (token.isEmpty) return null;
  final store = patrolStore;
  final pending = await store.unsyncedOfficeVisits();
  if (pending.isEmpty) return null;
  try {
    final ok = await PatrolClient()
        .officeSync(token, await DeviceFingerprint.get(), pending);
    if (ok) {
      for (final v in pending) {
        await store.markOfficeVisitSynced(v.id);
      }
    }
    return ok ? null : 'The server did not accept the office round — it stays saved and will retry.';
  } on PatrolDeviceRejected catch (e) {
    return e.message;
  } on Object {
    return null;
  }
}

/// The combined pending count the round headers and profile show.
Future<int> pendingTotal() async =>
    await patrolStore.pendingPatrolCount() + await patrolStore.pendingOfficeCount();