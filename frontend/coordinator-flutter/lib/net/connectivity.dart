import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'net.dart';

/// Whether the gateway answered a budget health request recently.
enum NetStatus { unknown, online, offline }

/// Global reachability, shared by the offline banner and the auto-sync ticker.
///
/// Reachability here means "the gateway answered a cheap request just now" — the
/// same thing every API call needs, which makes it the right proxy. The monitor
/// is the ONE probe on the phone: screens do not ping health every build, this
/// probe runs on a beat and every caller reads the shared [netStatus].
final ValueNotifier<NetStatus> netStatus = ValueNotifier(NetStatus.unknown);

/// Listeners that every successful probe calls — the beat the patroller app rides
/// to drain its pending queues in the background, so a round recorded in a lift
/// reaches the server the moment the phone comes back, with nobody pressing sync.
final List<ValueChanged<bool>> onOnlineBeats = [];

Timer? _timer;
int _inFlight = 0;

/// The periodic reachability probe + the offline→online transition hooks the tabs
/// need. Started once from main(); deliberately inert under `flutter test`, where a
/// repeating 25-second timer nobody asked for would hang every `pumpAndSettle`.
class NetMonitor {
  NetMonitor._();

  static void start({
    Duration every = const Duration(seconds: 25),
    Duration timeout = const Duration(seconds: 4),
  }) {
    if (Platform.environment['FLUTTER_TEST'] != null) return;
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => probe(timeout: timeout));
    probe(timeout: timeout);
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> probe({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_inFlight > 0) return; // one probe in flight is plenty
    _inFlight++;
    try {
      final r = await Net.shared
          .get(Uri.parse('${Net.baseUrl}/health'))
          .timeout(timeout);
      final online = r.statusCode >= 200 && r.statusCode < 500;
      if (online) {
        final wasOffline = netStatus.value == NetStatus.offline;
        netStatus.value = NetStatus.online;
        for (final cb in List.of(onOnlineBeats)) {
          try {
            cb(wasOffline);
          } on Object {
            // A beat must never take the probe down with it.
          }
        }
      } else {
        netStatus.value = NetStatus.offline;
      }
    } on Object {
      netStatus.value = NetStatus.offline;
    } finally {
      _inFlight--;
    }
  }
}
