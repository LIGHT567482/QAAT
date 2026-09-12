import 'package:flutter/foundation.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';

/// A register opened on THIS phone (via `POST /sessions/open`): the session the
/// home tab can close and the Session tab shows a code for.
class TodaySession {
  const TodaySession({
    required this.sessionId,
    required this.unitId,
    required this.unitName,
    required this.studentCode,
    required this.windowEnd,
  });

  final String sessionId;
  final String unitId;
  final String unitName;
  final String studentCode;
  final String windowEnd;
}

/// Shared coordinator state — the Flutter counterpart of the native `AppState`
/// (ui/AppState.kt), holding only what the coordinator dashboards need.
///
/// Values are [ValueNotifier]s so the top bar, the home cards and the tabs all
/// observe the same source of truth. Nothing here survives a sign-out; the
/// persistent sign-in itself lives in [SessionStore].
class CoordinatorState {
  CoordinatorState._();

  static const client = CoordinatorClient();

  /// The last good `/coordinator/overview` — kept on the hub so a refresh that
  /// fails (offline, server waking) leaves the timetable and units visible.
  static final overview = ValueNotifier<CoordOverview?>(null);

  /// Live sessions, server-side truth, refreshed with ⟳ and after each close.
  static final activeSessions = ValueNotifier<List<ActiveSession>>(const []);

  /// One-line cohort label, shown in the profile popup.
  static final cohortLabel = ValueNotifier<String?>(null);

  /// The register opened on this phone, shown as the big code on the Session tab.
  static final todaySession = ValueNotifier<TodaySession?>(null);

  /// One-shot lifecycle notice (auto-close fired / "end the current one first").
  static final sessionNotice = ValueNotifier<String?>(null);

  /// ⟳ spinner in the hub's top bar.
  static final refreshing = ValueNotifier<bool>(false);

  /// Bumped after every ⟳ so tabs that reload on it know a new pass began.
  static final refreshTick = ValueNotifier<int>(0);

  /// The one live session this phone opened (if any) — the native `activeSessionId`.
  static String? get activeSessionId => todaySession.value?.sessionId;

  static Future<void> refreshOverview(LoginResult r) async {
    final o = await client.overview(r.token);
    if (o == null) return; // keep the last good copy (mirrors dashboard fallback)
    overview.value = o;
    final offer = o.offering;
    if (offer != null) {
      cohortLabel.value = [
        offer.school,
        offer.department,
        offer.courseName,
        offer.sessionType,
        if (offer.studyYear > 0) 'Year ${offer.studyYear}',
        if (offer.semester > 0) 'Sem ${offer.semester}',
        offer.level,
        offer.intake,
      ].where((s) => s.isNotEmpty).join(' · ');
    }
  }

  static Future<void> refreshActive(LoginResult r) async {
    activeSessions.value = await client.activeSessions(r.token);
  }

  /// What the hub's ⟳ does: overview + active sessions, then every tab reloads
  /// on the bumped tick. Mirrors the native `refreshAll()`.
  static Future<void> refreshAll(LoginResult r) async {
    await refreshOverview(r);
    await refreshActive(r);
  }

  static void clearOpenRegister() => todaySession.value = null;
}