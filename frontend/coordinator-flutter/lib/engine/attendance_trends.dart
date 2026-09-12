class WeekInput {
  final String label;
  final int attended;
  final int possible;

  const WeekInput(this.label, this.attended, this.possible);
}

class WeekPoint {
  final String label;
  final double ratePct;
  final bool belowThreshold;

  const WeekPoint(this.label, this.ratePct, this.belowThreshold);
}

enum Trend { rising, falling, stable }

class AttendanceSummary {
  final List<WeekPoint> weeks;
  final double currentWeekRate;
  final double semesterAverage;
  final WeekPoint? bestWeek;
  final WeekPoint? worstWeek;
  final int totalSessions;
  final int weeksBelowThreshold;
  final Trend trend;

  const AttendanceSummary(
    this.weeks,
    this.currentWeekRate,
    this.semesterAverage,
    this.bestWeek,
    this.worstWeek,
    this.totalSessions,
    this.weeksBelowThreshold,
    this.trend,
  );
}

class AttendanceTrends {
  final double thresholdPct;

  AttendanceTrends({this.thresholdPct = 75.0});

  AttendanceSummary compute(List<WeekInput> weeks) {
    final pts = [
      for (final w in weeks)
        WeekPoint(
          w.label,
          w.possible > 0 ? w.attended / w.possible * 100.0 : 0.0,
          w.possible > 0 ? w.attended / w.possible * 100.0 < thresholdPct : true,
        ),
    ];
    if (pts.isEmpty) {
      return const AttendanceSummary([], 0.0, 0.0, null, null, 0, 0, Trend.stable);
    }

    final current = pts.last.ratePct;
    final totalAttended = weeks.fold<int>(0, (acc, w) => acc + w.attended);
    final totalPossible = weeks.fold<int>(0, (acc, w) => acc + w.possible);
    final avg = totalPossible > 0 ? totalAttended / totalPossible * 100.0 : 0.0;

    WeekPoint? best;
    WeekPoint? worst;
    for (final p in pts) {
      if (best == null || p.ratePct > best.ratePct) best = p;
      if (worst == null || p.ratePct < worst.ratePct) worst = p;
    }
    final belowCount = pts.where((p) => p.belowThreshold).length;
    final Trend trend;
    if (pts.length < 2) {
      trend = Trend.stable;
    } else {
      final delta = pts.last.ratePct - pts[pts.length - 2].ratePct;
      if (delta.abs() < 1.0) {
        trend = Trend.stable;
      } else if (delta > 0) {
        trend = Trend.rising;
      } else {
        trend = Trend.falling;
      }
    }

    return AttendanceSummary(
      pts,
      current,
      avg,
      best,
      worst,
      weeks.length,
      belowCount,
      trend,
    );
  }
}