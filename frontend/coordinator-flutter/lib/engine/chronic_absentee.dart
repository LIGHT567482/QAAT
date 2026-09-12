enum AbsenteeStatus { warning, critical }

class Flagged {
  final String studentId;
  final int consecutiveMissed;
  final double attendancePct;
  final AbsenteeStatus status;
  final String? lastAttendedSession;

  const Flagged(
    this.studentId,
    this.consecutiveMissed,
    this.attendancePct,
    this.status,
    this.lastAttendedSession,
  );
}

class ChronicAbsentee {
  final int consecutiveThreshold;
  final double lowAttendancePct;

  ChronicAbsentee({
    this.consecutiveThreshold = 3,
    this.lowAttendancePct = 25.0,
  });

  List<Flagged> evaluate(
    List<String> sessionsChrono,
    Map<String, Set<String>> attendedBy,
    List<String> students,
  ) {
    if (sessionsChrono.isEmpty) return const [];
    final total = sessionsChrono.length;
    final out = <Flagged>[];
    for (final s in students) {
      final attended = attendedBy[s] ?? const <String>{};
      var consec = 0;
      for (final sid in sessionsChrono.reversed) {
        if (attended.contains(sid)) break;
        consec++;
      }
      final pct = attended.length / total * 100.0;
      final lowFlag = pct < lowAttendancePct;
      final consecFlag = consec >= consecutiveThreshold;
      AbsenteeStatus? status;
      if (lowFlag && consecFlag) {
        status = AbsenteeStatus.critical;
      } else if (lowFlag || consecFlag) {
        status = AbsenteeStatus.warning;
      }
      if (status == null) continue;
      final lastAttended = sessionsChrono.lastWhere((sid) => attended.contains(sid),
          orElse: () => '');
      out.add(Flagged(
        s,
        consec,
        pct,
        status,
        lastAttended.isEmpty ? null : lastAttended,
      ));
    }
    out.sort((a, b) {
      final ac = a.status == AbsenteeStatus.critical ? 1 : 0;
      final bc = b.status == AbsenteeStatus.critical ? 1 : 0;
      final byStatus = bc.compareTo(ac);
      if (byStatus != 0) return byStatus;
      return b.consecutiveMissed.compareTo(a.consecutiveMissed);
    });
    return out;
  }
}