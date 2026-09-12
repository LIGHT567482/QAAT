import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import 'app_state.dart';

/// Weekly attendance trend + summary — a faithful port of the native
/// `TrendsScreen`: the threshold line (dashed), the rate line, points red when
/// below threshold, and the summary stats. Consumes the same `/coordinator/trends`
/// the dashboard (and the native client) is built from.
class TrendsTab extends StatefulWidget {
  const TrendsTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<TrendsTab> createState() => _TrendsTabState();
}

class _TrendsTabState extends State<TrendsTab> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  TrendSummary? _summary;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    CoordinatorState.refreshTick.addListener(_load);
  }

  @override
  void dispose() {
    CoordinatorState.refreshTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final s = await _client.trends(widget.result.token);
    if (mounted) {
      setState(() {
        _summary = s;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _summary;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Attendance trend',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (!_loaded)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: LinearProgressIndicator(),
          )
        else if (s == null || s.weeks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              s == null
                  ? "Couldn't load the trend right now — pull ⟳ to retry."
                  : 'No completed sessions yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: CustomPaint(
                size: Size.infinite,
                painter: _TrendPainter(
                  weeks: s.weeks,
                  threshold: s.threshold,
                  lineColor: scheme.primary,
                  belowColor: scheme.error,
                  gridColor: scheme.outlineVariant,
                ),
              ),
            ),
          ),
          _stat(scheme, 'Current week', '${s.currentWeekRate.toStringAsFixed(0)}%'),
          _stat(scheme, 'Semester average', '${s.semesterAverage.toStringAsFixed(0)}%'),
          if (s.bestWeek != null)
            _stat(scheme, 'Best week', '${s.bestWeek!.label} · ${s.bestWeek!.ratePct.toStringAsFixed(0)}%'),
          if (s.worstWeek != null)
            _stat(scheme, 'Worst week', '${s.worstWeek!.label} · ${s.worstWeek!.ratePct.toStringAsFixed(0)}%'),
          _stat(scheme, 'Weeks below threshold', '${s.weeksBelow}'),
          _stat(
            scheme,
            'Trend',
            switch (s.trend) {
              'RISING' => 'Rising ↑',
              'FALLING' => 'Falling ↓',
              _ => 'Stable →',
            },
          ),
        ],
      ],
    );
  }

  Widget _stat(ColorScheme scheme, String label, String value) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
        visualDensity: VisualDensity.compact,
      );
}

/// The native Canvas chart: a dashed threshold line at `threshold`%, the multi-
/// segment line of weekly rates, and a dot per week (red when below threshold).
class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.weeks,
    required this.threshold,
    required this.lineColor,
    required this.belowColor,
    required this.gridColor,
  });

  final List<TrendWeek> weeks;
  final int threshold;
  final Color lineColor;
  final Color belowColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (weeks.isEmpty) return;
    final w = size.width;
    final h = size.height;

    double x(int i) => weeks.length == 1 ? w / 2 : w * i / (weeks.length - 1);
    double y(double ratePct) => h - (ratePct / 100.0) * h;

    final dash = Paint()
      ..color = gridColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, y(threshold.toDouble())),
      Offset(w, y(threshold.toDouble())),
      dash,
    );

    final path = Path();
    for (final (i, p) in weeks.indexed) {
      final px = x(i);
      final py = y(p.ratePct);
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    for (final (i, p) in weeks.indexed) {
      canvas.drawCircle(
        Offset(x(i), y(p.ratePct)),
        7,
        Paint()..color = p.belowThreshold ? belowColor : lineColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.weeks != weeks ||
      old.threshold != threshold ||
      old.lineColor != lineColor ||
      old.belowColor != belowColor ||
      old.gridColor != gridColor;
}