import '../patrol/patrol_models.dart';

/// The OFFLINE office search, mirroring the server's OfficeSearch exactly.
///
/// The rule lives in one function with a test on it rather than inline in a screen
/// nothing can exercise — the two implementations diverging is a silent failure: a
/// monitor standing at the right door is told nobody by that name works there.
///
/// Prefix-match the badge (a monitor types the start of "kiu/0" off a card, and
/// "044" as a contains-match would hit a third of the institution); contains-match
/// the name, department and office (a registry name is "DR ANUMOLU SRINIVASA RAO",
/// the nameplate says "ANUMOLU").
class OfficeSearchMatch {
  OfficeSearchMatch._();

  static bool matches(OfficePerson p, String query) {
    final needle = query.trim().toLowerCase();
    // An empty query matches nobody, deliberately — the server's rule; a round
    // that opens on everybody invites recording without visiting.
    if (needle.isEmpty) return false;
    return _norm(p.staffId).startsWith(needle) ||
        _norm(p.fullName).contains(needle) ||
        _norm(p.department).contains(needle) ||
        _norm(p.office).contains(needle);
  }

  static List<OfficePerson> filter(List<OfficePerson> people, String query) =>
      people.where((p) => matches(p, query)).toList()
        ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));

  /// btrim(lower(COALESCE(x,''))) — the server normalises both sides, so this must too.
  static String _norm(String s) => s.trim().toLowerCase();
}