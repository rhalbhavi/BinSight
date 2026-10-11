import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:binsight/services/api_service.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, required this.drawer});

  final Widget drawer;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<Map<String, dynamic>> _bins = [];
  List<_FillPoint> _history = [];
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  DateTime _selectedDay = DateUtils.dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        ApiService.fetchAnalyticsFillHistory(),
        ApiService.fetchDevices(),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final bins = (data['bins'] as List<dynamic>? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      final history = (data['history'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                _FillPoint.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .whereType<_FillPoint>()
          .toList();
      if (!mounted) return;
      setState(() {
        _bins = bins;
        _history = history;
        _devices = results[1] as List<Map<String, dynamic>>;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  String _binName(String id) {
    for (final bin in _bins) {
      if (bin['device_id']?.toString() == id) {
        return bin['name']?.toString() ?? id;
      }
    }
    return id;
  }

  List<_GraphGroup> get _graphs {
    final dayStart = DateTime(
      _selectedDay.year,
      _selectedDay.month,
      _selectedDay.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));
    final pointsByBin = <String, List<_FillPoint>>{};
    for (final point in _history) {
      final localTime = point.time.toLocal();
      if (!localTime.isBefore(dayStart) && localTime.isBefore(dayEnd)) {
        pointsByBin.putIfAbsent(point.deviceId, () => []).add(point);
      }
    }
    final zones = <String, List<MapEntry<String, List<_FillPoint>>>>{};
    final zoneNames = <String, String>{};
    final unassigned = <_GraphGroup>[];
    for (final bin in _bins) {
      final id = bin['device_id']?.toString() ?? '';
      final points = pointsByBin[id] ?? const <_FillPoint>[];
      if (points.isEmpty) continue;
      final zoneId = bin['zone_id']?.toString() ?? '';
      final line = MapEntry(id, points);
      if (zoneId.isEmpty) {
        unassigned.add(
          _GraphGroup(
            title: _binName(id),
            subtitle: 'Bin without an assigned zone',
            series: [line],
            isZone: false,
          ),
        );
      } else {
        zones.putIfAbsent(zoneId, () => []).add(line);
        zoneNames[zoneId] = bin['zone_name']?.toString().isNotEmpty == true
            ? bin['zone_name'].toString()
            : zoneId;
      }
    }
    final grouped = zones.entries
        .map(
          (entry) => _GraphGroup(
            title: zoneNames[entry.key] ?? entry.key,
            subtitle: 'Hourly fill level · each line is an assigned bin',
            series: entry.value,
            isZone: true,
          ),
        )
        .toList();
    return [...grouped, ...unassigned];
  }

  List<Map<String, dynamic>> get _metricDevices =>
      _devices.where((device) => device['type'] == 'bin').toList();

  @override
  Widget build(BuildContext context) {
    final graphs = _graphs;
    final zoneGraphs = graphs.where((graph) => graph.isZone).toList();
    final unassignedGraphs = graphs.where((graph) => !graph.isZone).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF03A9F4),
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/logo.png',
                height: 32,
                width: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'BinSight',
              style: GoogleFonts.rubikMonoOne(
                color: Colors.white,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
      drawer: widget.drawer,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Icon(Icons.insights, size: 22),
                const SizedBox(width: 8),
                Text(
                  'Analytics',
                  style: GoogleFonts.rubikMonoOne(
                    fontSize: 20,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            const SizedBox(height: 6),
            Text(
              'Fill patterns and live risk estimates for registered bins/zones.',
              style: GoogleFonts.titilliumWeb(
                fontSize: 16,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading && _history.isEmpty)
              const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              _buildDailyAnalytics(zoneGraphs, unassignedGraphs),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Refresh failed: $_error',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            const SizedBox(height: 25),
            Text(
              'Predictive metrics',
              style: GoogleFonts.rubikMonoOne(fontSize: 17),
            ),
            const SizedBox(height: 4),
            Text(
              'Estimates update with the latest device data. They are indicators for review, not guaranteed outcomes.',
              style: GoogleFonts.titilliumWeb(
                fontSize: 14,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 10),
            if (_loading && _devices.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_metricDevices.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No registered bins are available.'),
                ),
              )
            else
              ..._metricDevices.map(_buildMetricsCard),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyAnalytics(
    List<_GraphGroup> zoneGraphs,
    List<_GraphGroup> unassignedGraphs,
  ) {
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDay = today.subtract(const Duration(days: 6));
    final canGoBack = _selectedDay.isAfter(firstDay);
    final canGoForward = _selectedDay.isBefore(today);
    final dayLabel = MaterialLocalizations.of(
      context,
    ).formatFullDate(_selectedDay);
    final charts = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: RichText(
            text: TextSpan(
              children: [
                if (DateUtils.isSameDay(_selectedDay, today))
                  TextSpan(
                    text: 'Today - ',
                    style: GoogleFonts.rubikMonoOne(
                      fontSize: 17,
                      color: Colors.black87,
                    ),
                  ),
                TextSpan(
                  text: dayLabel,
                  style: GoogleFonts.titilliumWeb(
                    fontSize: 17,
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 18),
        const SizedBox(height: 8),
        if (zoneGraphs.isNotEmpty) ...[
          _sectionHeading('Zone fill patterns'),
          const SizedBox(height: 8),
          ...zoneGraphs.map(_buildGraphCard),
        ],
        if (unassignedGraphs.isNotEmpty) ...[
          _sectionHeading('Unassigned bin fill patterns'),
          const SizedBox(height: 8),
          ...unassignedGraphs.map(_buildGraphCard),
        ],
        if (zoneGraphs.isEmpty && unassignedGraphs.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text('No valid fill telemetry was recorded on this day.'),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: canGoBack
                  ? () => setState(() {
                      _selectedDay = _selectedDay.subtract(
                        const Duration(days: 1),
                      );
                    })
                  : null,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Previous day'),
            ),
            Text('${_selectedDay.difference(firstDay).inDays + 1} of 7'),
            TextButton.icon(
              onPressed: canGoForward
                  ? () => setState(() {
                      _selectedDay = _selectedDay.add(const Duration(days: 1));
                    })
                  : null,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next day'),
            ),
          ],
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 980) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              charts,
              const SizedBox(height: 12),
              _buildMonthCalendar(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: charts),
            const SizedBox(width: 16),
            SizedBox(width: 300, child: _buildMonthCalendar()),
          ],
        );
      },
    );
  }

  Widget _buildMonthCalendar() {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(now.year, now.month);
    final leadingDays = monthStart.weekday - 1;
    final weekCount = ((leadingDays + daysInMonth) / 7).ceil();
    final monthPoints = _history.where((point) {
      final local = point.time.toLocal();
      return local.year == now.year && local.month == now.month;
    }).toList();
    final weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              MaterialLocalizations.of(context).formatMonthYear(now),
              style: GoogleFonts.titilliumWeb(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final label in weekdayLabels)
                  Expanded(
                    child: Center(
                      child: Text(label, style: const TextStyle(fontSize: 11)),
                    ),
                  ),
                const SizedBox(width: 55),
              ],
            ),
            for (var week = 0; week < weekCount; week++) ...[
              Row(
                children: [
                  for (var weekday = 0; weekday < 7; weekday++)
                    Expanded(
                      child: _buildCalendarDay(
                        week * 7 + weekday - leadingDays + 1,
                        daysInMonth,
                        now,
                        monthPoints,
                      ),
                    ),
                  SizedBox(
                    width: 55,
                    child: Text(
                      'Avg ${_averageForCalendarWeek(week, leadingDays, daysInMonth, monthPoints)}',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.titilliumWeb(
                        fontSize: 10,
                        color: Colors.blueGrey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Weekly average of hourly fill readings',
              style: GoogleFonts.titilliumWeb(
                fontSize: 12,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarDay(
    int day,
    int daysInMonth,
    DateTime now,
    List<_FillPoint> monthPoints,
  ) {
    if (day < 1 || day > daysInMonth) return const SizedBox(height: 30);
    final date = DateTime(now.year, now.month, day);
    final hasData = monthPoints.any((point) {
      final local = point.time.toLocal();
      return local.year == date.year &&
          local.month == date.month &&
          local.day == day;
    });
    final selected = DateUtils.isSameDay(date, _selectedDay);
    final today = DateUtils.isSameDay(date, DateUtils.dateOnly(now));
    return InkWell(
      onTap:
          date.isAfter(
                DateUtils.dateOnly(now).subtract(const Duration(days: 6)),
              ) &&
              !date.isAfter(DateUtils.dateOnly(now))
          ? () => setState(() => _selectedDay = date)
          : null,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 30,
        child: Center(
          child: Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              color: selected ? Colors.blue.shade700 : null,
              border: today && !selected
                  ? Border.all(color: Colors.blue.shade700)
                  : null,
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? Colors.white : Colors.black87,
                    fontWeight: today || selected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (hasData)
                  Positioned(
                    bottom: 1,
                    child: Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : Colors.teal,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _averageForCalendarWeek(
    int week,
    int leadingDays,
    int daysInMonth,
    List<_FillPoint> monthPoints,
  ) {
    final firstDayNumber = week * 7 - leadingDays + 1;
    final values = monthPoints
        .where((point) {
          final local = point.time.toLocal();
          final monthDay = local.day;
          return monthDay >= firstDayNumber &&
              monthDay < firstDayNumber + 7 &&
              monthDay <= daysInMonth;
        })
        .map((point) => point.fill)
        .toList();
    if (values.isEmpty) return '—';
    final average = values.reduce((a, b) => a + b) / values.length;
    return '${average.round()}%';
  }

  Widget _sectionHeading(String text) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(text, style: GoogleFonts.rubikMonoOne(fontSize: 16)),
  );

  Widget _buildGraphCard(_GraphGroup group) {
    final start = DateTime(
      _selectedDay.year,
      _selectedDay.month,
      _selectedDay.day,
    );
    final end = start.add(const Duration(days: 1));
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              group.title,
              style: GoogleFonts.titilliumWeb(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              group.subtitle,
              style: GoogleFonts.titilliumWeb(
                fontSize: 14,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 250,
              width: double.infinity,
              child: CustomPaint(
                painter: _FillHistoryPainter(
                  series: group.series,
                  start: start,
                  end: end,
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                _LegendItem(color: _normalColor, label: 'Normal · 0–49%'),
                _LegendItem(color: _moderateColor, label: 'Moderate · 50–69%'),
                _LegendItem(
                  color: _almostFullColor,
                  label: 'Almost full · 70–89%',
                ),
                _LegendItem(color: _fullColor, label: 'Full · 90–100%'),
              ],
            ),
            if (group.series.length > 1) ...[
              const SizedBox(height: 6),
              Text(
                'Lines show bins: ${group.series.map((line) => _binName(line.key)).join(', ')}',
                style: GoogleFonts.titilliumWeb(
                  fontSize: 12,
                  color: Colors.black54,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsCard(Map<String, dynamic> device) {
    final id = (device['bin_id'] ?? device['id'] ?? '').toString();
    final name = device['name']?.toString() ?? _binName(id);
    final overflow =
        device['next_overflow_time']?.toString() ?? 'Insufficient trend';
    final overflowMethod =
        device['overflow_forecast_method']?.toString() ??
        'ARIMA forecast unavailable';
    final gas = device['gas_level']?.toString() ?? '—';
    final zScore = device['gas_z_score']?.toString() ?? 'Unavailable';
    final gasSpike = device['gas_spike'] == true;
    final fireRisk = device['fire_risk'] == true;
    final flame = device['flame'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: GoogleFonts.titilliumWeb(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            _metricRow(
              icon: Icons.schedule,
              heading: 'Next overflow time',
              value: overflow,
              detail: '$overflowMethod · based on valid hourly fill history.',
              color: Colors.blue.shade700,
            ),
            const Divider(height: 24),
            _metricRow(
              icon: Icons.air,
              heading: 'Gas spike',
              value: gasSpike ? 'Spike detected' : 'No spike detected',
              detail: '$gas PPM · Z-score $zScore (spike threshold: +3)',
              color: gasSpike ? Colors.deepOrange : Colors.green.shade700,
            ),
            const Divider(height: 24),
            _metricRow(
              icon: Icons.local_fire_department_outlined,
              heading: 'Fire risk',
              value: fireRisk ? 'Elevated' : 'No elevated risk',
              detail: flame
                  ? 'Flame sensor currently detects flame.'
                  : 'No current flame detection.',
              color: fireRisk ? Colors.red.shade700 : Colors.green.shade700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricRow({
    required IconData icon,
    required String heading,
    required String value,
    required String detail,
    required Color color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                heading,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                value,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 17,
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                detail,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 14,
                  color: Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GraphGroup {
  const _GraphGroup({
    required this.title,
    required this.subtitle,
    required this.series,
    required this.isZone,
  });

  final String title;
  final String subtitle;
  final List<MapEntry<String, List<_FillPoint>>> series;
  final bool isZone;
}

class _FillPoint {
  const _FillPoint({
    required this.deviceId,
    required this.time,
    required this.fill,
  });

  final String deviceId;
  final DateTime time;
  final double fill;

  static _FillPoint? fromMap(Map<String, dynamic> map) {
    final time = DateTime.tryParse(map['timestamp']?.toString() ?? '');
    final fill = map['fill_level'];
    if (time == null || fill is! num) return null;
    return _FillPoint(
      deviceId: map['device_id']?.toString() ?? '',
      time: time,
      fill: fill.toDouble(),
    );
  }
}

const Color _normalColor = Color(0xFF43A047);
const Color _moderateColor = Color(0xFFFBC02D);
const Color _almostFullColor = Color(0xFFFB8C00);
const Color _fullColor = Color(0xFFE53935);

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 16,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: GoogleFonts.titilliumWeb(fontSize: 14)),
    ],
  );
}

class _PlotPoint {
  const _PlotPoint(this.position, this.fill);
  final Offset position;
  final double fill;
}

class _FillHistoryPainter extends CustomPainter {
  _FillHistoryPainter({
    required this.series,
    required this.start,
    required this.end,
  });

  final List<MapEntry<String, List<_FillPoint>>> series;
  final DateTime start;
  final DateTime end;

  Color _colorForFill(double fill) {
    if (fill >= 90) return _fullColor;
    if (fill >= 70) return _almostFullColor;
    if (fill >= 50) return _moderateColor;
    return _normalColor;
  }

  List<List<_PlotPoint>> _plotRuns(Rect chart, int duration) {
    final runs = <List<_PlotPoint>>[];
    for (final line in series) {
      List<_PlotPoint>? run;
      DateTime? previousTime;
      for (final point in line.value) {
        if (previousTime != null &&
            point.time.difference(previousTime).inHours > 3) {
          if (run != null && run.isNotEmpty) runs.add(run);
          run = null;
        }
        run ??= <_PlotPoint>[];
        final x =
            chart.left +
            (point.time.difference(start).inMilliseconds / duration) *
                chart.width;
        final fill = point.fill.clamp(0, 100).toDouble();
        final y = chart.bottom - fill / 100 * chart.height;
        run.add(_PlotPoint(Offset(x, y), fill));
        previousTime = point.time;
      }
      if (run != null && run.isNotEmpty) runs.add(run);
    }
    return runs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0;
    const right = 10.0;
    const top = 12.0;
    const bottom = 50.0;
    final chart = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final duration = math.max(1, end.difference(start).inMilliseconds);
    final runs = _plotRuns(chart, duration);
    canvas.save();
    canvas.clipRect(chart);

    // Subtle horizontal bands anchor the state colors to their thresholds.
    final bands = [
      (0.0, 50.0, _normalColor),
      (50.0, 70.0, _moderateColor),
      (70.0, 90.0, _almostFullColor),
      (90.0, 100.0, _fullColor),
    ];
    for (final (lower, upper, color) in bands) {
      final topY = chart.bottom - upper / 100 * chart.height;
      final bottomY = chart.bottom - lower / 100 * chart.height;
      canvas.drawRect(
        Rect.fromLTRB(chart.left, topY, chart.right, bottomY),
        Paint()..color = color.withValues(alpha: 0.055),
      );
    }

    final areaShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0x55E53935),
        Color(0x44FB8C00),
        Color(0x33FBC02D),
        Color(0x2243A047),
      ],
      stops: [0, 0.1, 0.3, 1],
    ).createShader(chart);
    for (final run in runs) {
      if (run.length < 2) continue;
      final area = Path()
        ..moveTo(run.first.position.dx, chart.bottom)
        ..lineTo(run.first.position.dx, run.first.position.dy);
      for (final point in run.skip(1)) {
        area.lineTo(point.position.dx, point.position.dy);
      }
      area
        ..lineTo(run.last.position.dx, chart.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = areaShader
          ..style = PaintingStyle.fill,
      );
    }

    final gridPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1;
    final labelStyle = TextStyle(color: Colors.grey.shade700, fontSize: 11);
    for (var level = 0; level <= 100; level += 25) {
      final y = chart.bottom - (level / 100) * chart.height;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      _drawText(
        canvas,
        '$level%',
        Offset(0, y - 7),
        labelStyle,
        maxWidth: left - 5,
      );
    }
    for (final threshold in [50.0, 70.0, 90.0]) {
      final y = chart.bottom - threshold / 100 * chart.height;
      canvas.drawLine(
        Offset(chart.left, y),
        Offset(chart.right, y),
        Paint()
          ..color = _colorForFill(threshold).withValues(alpha: 0.8)
          ..strokeWidth = 1.2,
      );
    }

    // Split each line segment where it crosses a status threshold so the
    // stroke changes color exactly at normal/moderate/almost-full boundaries.
    for (final run in runs) {
      if (run.length == 1) {
        canvas.drawCircle(
          run.single.position,
          3,
          Paint()..color = _colorForFill(run.single.fill),
        );
        continue;
      }
      for (var i = 0; i < run.length - 1; i++) {
        final first = run[i];
        final second = run[i + 1];
        final cuts = <double>[0, 1];
        for (final threshold in [50.0, 70.0, 90.0]) {
          final delta = second.fill - first.fill;
          if (delta == 0) continue;
          final t = (threshold - first.fill) / delta;
          if (t > 0 && t < 1) cuts.add(t);
        }
        cuts.sort();
        for (var cut = 0; cut < cuts.length - 1; cut++) {
          final t0 = cuts[cut];
          final t1 = cuts[cut + 1];
          final midT = (t0 + t1) / 2;
          final midFill = first.fill + (second.fill - first.fill) * midT;
          final p0 = Offset.lerp(first.position, second.position, t0)!;
          final p1 = Offset.lerp(first.position, second.position, t1)!;
          canvas.drawLine(
            p0,
            p1,
            Paint()
              ..color = _colorForFill(midFill)
              ..strokeWidth = 2.8
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }
    canvas.restore();

    final chartBottom = chart.bottom;
    final hourSlotWidth = chart.width / 24;
    final hourFontSize = math.min(9.0, math.max(7.0, hourSlotWidth * 0.72));
    final hourLabelStyle = TextStyle(
      color: Colors.grey.shade700,
      fontSize: hourFontSize,
    );
    final tickPaint = Paint()
      ..color = Colors.grey.shade500
      ..strokeWidth = 0.7;
    for (var hour = 0; hour < 24; hour++) {
      final centerX = chart.left + (hour + 0.5) * hourSlotWidth;
      canvas.drawLine(
        Offset(centerX, chartBottom),
        Offset(centerX, chartBottom + 3),
        tickPaint,
      );
      final hourOnClock = hour % 12 == 0 ? 12 : hour % 12;
      _drawText(
        canvas,
        '$hourOnClock',
        Offset(centerX - hourSlotWidth / 2, chartBottom + 5),
        hourLabelStyle,
        maxWidth: hourSlotWidth,
        align: TextAlign.center,
      );
    }
    final halfWidth = chart.width / 2;
    final periodStyle = TextStyle(
      color: Colors.grey.shade800,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    _drawText(
      canvas,
      'AM',
      Offset(chart.left, chartBottom + 24),
      periodStyle,
      maxWidth: halfWidth,
      align: TextAlign.center,
    );
    _drawText(
      canvas,
      'PM',
      Offset(chart.left + halfWidth, chartBottom + 24),
      periodStyle,
      maxWidth: halfWidth,
      align: TextAlign.center,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    required double maxWidth,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    );
    painter.layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _FillHistoryPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.start != start ||
      oldDelegate.end != end;
}
