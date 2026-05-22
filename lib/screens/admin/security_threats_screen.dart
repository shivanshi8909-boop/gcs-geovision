
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_sidebar.dart';
import '../../widgets/common_widgets.dart';
import '../../services/face_server_service.dart';

class SecurityThreatsScreen extends StatefulWidget {
  const SecurityThreatsScreen({super.key});
  @override
  State<SecurityThreatsScreen> createState() => _SecurityThreatsScreenState();
}

class _SecurityThreatsScreenState extends State<SecurityThreatsScreen> {

  _ThreatItem? _selected;

  // Real threats built from InsightFace SSE events
  final List<_ThreatItem> _threats = [];



  static const _guards = [
    {'name': 'Rajan Kumar',  'id': 'GRD-001', 'zone': 'North Campus', 'init': 'RK', 'eta': '~2 min'},
    {'name': 'Suresh Patil', 'id': 'GRD-002', 'zone': 'East Zone',    'init': 'SP', 'eta': '~4 min'},
    {'name': 'Vikram Singh', 'id': 'GRD-003', 'zone': 'Main Gate',    'init': 'VS', 'eta': '~1 min'},
  ];

  static const _pieData = [
    ['Unauthorized Access', '#dc2626', 2],
    ['Tailgating',          '#f59e0b', 2],
    ['Low Confidence',      '#6366f1', 2],
    ['Blacklisted',         '#7c3aed', 1],
    ['Curfew Breach',       '#0891b2', 1],
  ];

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Prime with a couple of placeholder threats so the list isn't empty
    _threats.add(_ThreatItem(
      icon: '🚫', title: 'Unknown face detected', type: 'Unauthorized Access',
      gate: 'North Gate', severity: 'Critical', status: 'Active',
      time: DateTime.now().subtract(const Duration(minutes: 3)),
      confidence: 34.2, camera: 'CAM-01',
    ));
    _threats.add(_ThreatItem(
      icon: '🔍', title: 'Low confidence match', type: 'Low Confidence Scan',
      gate: 'Library Entrance', severity: 'Medium', status: 'Resolving',
      time: DateTime.now().subtract(const Duration(minutes: 8)),
      confidence: 41.7, camera: 'CAM-02',
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToFaceServer();
  }

  @override
  void dispose() {
    // Remove listener from FaceServerService
    try {
      context.read<FaceServerService>().removeListener(_onFaceServerEvent);
    } catch (_) {}
    super.dispose();
  }

  // ── Connect to InsightFace SSE ─────────────────────────────────────────────

  bool _subscribed = false;

  void _subscribeToFaceServer() {
    if (_subscribed) return;
    _subscribed = true;
    final fr = context.read<FaceServerService>();

    // Ensure SSE is running
    fr.startSSE();

    // Listen for changes
    fr.addListener(_onFaceServerEvent);
  }

  void _onFaceServerEvent() {
    if (!mounted) return;
    final fr = context.read<FaceServerService>();

    // Check the latest event
    if (fr.events.isEmpty) return;
    final latest = fr.events.first;

    // Only care about threat-type recognition events
    if (latest.type != 'recognition') return;
    final data = latest.data;
    if ((data['event_type'] as String?) != 'threat') return;

    // Dedupe — don't add the same timestamp twice
    final ts = latest.ts;
    if (_threats.isNotEmpty && _threats.first.time == ts) return;

    final camera = data['camera'] as String? ?? 'Unknown Camera';
    final conf   = (data['confidence'] as num?)?.toDouble() ?? 0;

    // Pick icon/title based on confidence level
    final String icon, title, type, severity;
    if (conf < 20) {
      icon     = '🚫'; title = 'Unknown face detected';
      type     = 'Unauthorized Access'; severity = 'Critical';
    } else if (conf < 35) {
      icon     = '🚷'; title = 'Possible blacklisted individual';
      type     = 'Blacklisted Individual'; severity = 'High';
    } else {
      icon     = '🔍'; title = 'Low confidence match';
      type     = 'Low Confidence Scan'; severity = 'Medium';
    }

    setState(() {
      _threats.insert(0, _ThreatItem(
        icon:       icon,
        title:      title,
        type:       type,
        gate:       _cameraToGate(camera),
        severity:   severity,
        status:     'Active',
        time:       ts,
        confidence: conf,
        camera:     camera,
      ));
      if (_threats.length > 20) _threats.removeLast();
    });
  }

  String _cameraToGate(String camera) {
    final cam = camera.toLowerCase();
    if (cam.contains('cam-01') || cam.contains('main')) return 'Main Gate';
    if (cam.contains('cam-02') || cam.contains('lib'))  return 'Library';
    if (cam.contains('cam-03') || cam.contains('east')) return 'East Entrance';
    if (cam.contains('cam-04') || cam.contains('lab'))  return 'Lab Block';
    if (cam.contains('cam-05') || cam.contains('admin'))return 'Admin Block';
    return camera;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color _hexColor(String hex) {
    try { return Color(int.parse(hex.trim().replaceAll('#', '0xFF'))); }
    catch (_) { return GeoColors.primary; }
  }

  Color _sevColor(String sev) => switch (sev) {
    'Critical' => GeoColors.danger,
    'High'     => GeoColors.warning,
    'Medium'   => const Color(0xFF6366F1),
    _          => const Color(0xFF888888),
  };

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme    = context.watch<ThemeNotifier>();
    final fr       = context.watch<FaceServerService>();
    final active   = _threats.where((t) => t.status == 'Active').length;
    final resolving= _threats.where((t) => t.status == 'Resolving').length;
    final resolved = _threats.where((t) => t.status == 'Resolved').length;

    return AdminShell(
      activeRoute: '/admin/threats',
      breadcrumb:  'Security Threats',
      pageTitle:   'Security Threats',
      topbarActions: [
        // SSE connection status pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: fr.sseConnected
                ? GeoColors.successGhost
                : GeoColors.dangerGhost,
            borderRadius: BorderRadius.circular(GeoRadius.full),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fr.sseConnected ? GeoColors.success : GeoColors.danger)),
            const SizedBox(width: 6),
            Text(
              fr.sseConnected ? 'InsightFace Live' : 'InsightFace Offline',
              style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700,
                color: fr.sseConnected ? GeoColors.success : GeoColors.danger)),
          ]),
        ),
        const SizedBox(width: 8),
        const LiveBadge(),
        const SizedBox(width: 8),
        _topBtn('⬇ Export', theme),
      ],
      body: Stack(children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Security Threats', style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: theme.textPrimary)),
            const SizedBox(height: 4),
            Text('Real-time monitoring powered by InsightFace recognition.',
                style: GoogleFonts.inter(fontSize: 13, color: theme.textSecondary)),
            const SizedBox(height: 20),

            // Top section: pie + stats
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Pie card
              Container(
                width: 320,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                    color: theme.bgCard, border: Border.all(color: theme.border),
                    borderRadius: BorderRadius.circular(GeoRadius.lg)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('📊 Threat Breakdown', style: GoogleFonts.inter(
                      fontSize: 14, fontWeight: FontWeight.w700, color: theme.textPrimary)),
                  const SizedBox(height: 18),
                  Center(child: SizedBox(width: 200, height: 200,
                    child: Stack(children: [
                      CustomPaint(size: const Size(200, 200), painter: _PiePainter(_pieData)),
                      Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${_threats.length}', style: GoogleFonts.inter(
                            fontSize: 28, fontWeight: FontWeight.w800, color: theme.textPrimary)),
                        Text('Total', style: GoogleFonts.inter(
                            fontSize: 11, color: theme.textTertiary)),
                      ])),
                    ]),
                  )),
                  const SizedBox(height: 16),
                  ..._pieData.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(color: _hexColor(d[1] as String), shape: BoxShape.circle)),
                        Expanded(child: Text(d[0] as String,
                            style: GoogleFonts.inter(fontSize: 12, color: theme.textPrimary))),
                        Text('${d[2]}', style: GoogleFonts.inter(
                            fontSize: 12, fontWeight: FontWeight.w700, color: theme.textPrimary)),
                      ]))),
                ]),
              ),
              const SizedBox(width: 20),

              // Stats right
              Expanded(child: Column(children: [
                Row(children: [
                  Expanded(child: StatCard(theme: theme, icon: '🚨',
                      value: '$active', label: 'Active Threats',
                      trend: '▲ Real-time', trendUp: false,
                      iconBg: GeoColors.dangerGhost)),
                  const SizedBox(width: 12),
                  Expanded(child: StatCard(theme: theme, icon: '⏳',
                      value: '$resolving', label: 'Being Resolved',
                      iconBg: GeoColors.warningGhost)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: StatCard(theme: theme, icon: '✓',
                      value: '$resolved', label: 'Resolved Today',
                      trend: 'InsightFace', trendUp: true,
                      iconBg: GeoColors.successGhost)),
                  const SizedBox(width: 12),
                  Expanded(child: StatCard(theme: theme, icon: '🔒',
                      value: '12', label: 'Guards On Duty')),
                ]),
                const SizedBox(height: 12),
                // Recent resolutions
                Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: theme.bgCard, border: Border.all(color: theme.border),
                        borderRadius: BorderRadius.circular(GeoRadius.lg)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('⏱ Recent Resolutions', style: GoogleFonts.inter(
                          fontSize: 14, fontWeight: FontWeight.w700, color: theme.textPrimary)),
                      const SizedBox(height: 12),
                      _recentRes(theme, 'Tailgating — Library · 09:15 AM'),
                      _recentRes(theme, 'Unknown Face — North Entry · 08:32 AM'),
                      _recentRes(theme, 'Curfew breach — Block D · 11:22 PM'),
                    ])),
              ])),
            ]),
            const SizedBox(height: 20),

            // ── Threat list ────────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                  color: theme.bgCard, border: Border.all(color: theme.border),
                  borderRadius: BorderRadius.circular(GeoRadius.lg)),
              child: Column(children: [
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(children: [
                      Text('⚠️ Active Threats', style: GoogleFonts.inter(
                          fontSize: 14, fontWeight: FontWeight.w700, color: theme.textPrimary)),
                      const SizedBox(width: 10),
                      Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                              color: GeoColors.dangerGhost,
                              borderRadius: BorderRadius.circular(GeoRadius.full)),
                          child: Text('$active Active', style: GoogleFonts.inter(
                              fontSize: 11, fontWeight: FontWeight.w600, color: GeoColors.danger))),
                      const SizedBox(width: 8),
                      // InsightFace badge
                      Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                              color: GeoColors.primaryGhost,
                              borderRadius: BorderRadius.circular(GeoRadius.full)),
                          child: Text('🧠 InsightFace', style: GoogleFonts.inter(
                              fontSize: 11, fontWeight: FontWeight.w600, color: GeoColors.primary))),
                    ])),
                // Header row
                Container(
                    color: theme.bgBadge,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(children: [
                      _th(theme, '', 40),
                      _th(theme, 'Incident', 0, flex: true),
                      _th(theme, 'Confidence', 100),
                      _th(theme, 'Severity', 90),
                      _th(theme, 'Status', 100),
                      _th(theme, 'Action', 100),
                    ])),
                Divider(height: 1, color: theme.border),
                if (_threats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(children: [
                      const Text('✅', style: TextStyle(fontSize: 36)),
                      const SizedBox(height: 12),
                      Text('No threats detected', style: GoogleFonts.inter(
                          fontSize: 14, fontWeight: FontWeight.w600, color: theme.textSecondary)),
                      Text('InsightFace is monitoring in real-time',
                          style: GoogleFonts.inter(fontSize: 12, color: theme.textTertiary)),
                    ]),
                  )
                else
                  ..._threats.map((t) => _threatRow(theme, t)),
              ]),
            ),
          ]),
        ),

        // Detail panel
        if (_selected != null) ...[
          GestureDetector(
              onTap: () => setState(() => _selected = null),
              child: Container(color: Colors.black.withOpacity(.35))),
          Positioned(right: 0, top: 0, bottom: 0, child: _buildDetailPanel(theme)),
        ],
      ]),
    );
  }

  // ── Row builders ──────────────────────────────────────────────────────────

  Widget _recentRes(ThemeNotifier theme, String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 8),
            decoration: const BoxDecoration(color: GeoColors.success, shape: BoxShape.circle)),
        Expanded(child: Text(label, style: GoogleFonts.inter(
            fontSize: 12, fontWeight: FontWeight.w500, color: theme.textPrimary))),
        Text('✓ Resolved', style: GoogleFonts.inter(
            fontSize: 12, fontWeight: FontWeight.w700, color: GeoColors.success)),
      ]));

  Widget _th(ThemeNotifier theme, String label, double w, {bool flex = false}) {
    final child = Text(label.toUpperCase(), style: GoogleFonts.inter(
        fontSize: 11, fontWeight: FontWeight.w700, color: theme.textTertiary, letterSpacing: .5));
    return flex ? Expanded(child: child) : SizedBox(width: w, child: child);
  }

  Widget _threatRow(ThemeNotifier theme, _ThreatItem t) {
    final sevColor = _sevColor(t.severity);
    final statusBg = t.status == 'Active'     ? GeoColors.dangerGhost
                   : t.status == 'Resolving'  ? GeoColors.warningGhost
                   : GeoColors.successGhost;
    final statusFg = t.status == 'Active'     ? GeoColors.danger
                   : t.status == 'Resolving'  ? GeoColors.warning
                   : GeoColors.success;
    final time = '${t.time.hour.toString().padLeft(2,'0')}:${t.time.minute.toString().padLeft(2,'0')}';

    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.border))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          SizedBox(width: 40, child: Text(t.icon, style: const TextStyle(fontSize: 22))),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, style: GoogleFonts.inter(
                fontSize: 13, fontWeight: FontWeight.w700, color: theme.textPrimary)),
            Text('📍 ${t.gate} · $time · ${t.camera}',
                style: GoogleFonts.inter(fontSize: 11, color: theme.textTertiary)),
          ])),
          // Confidence column
          SizedBox(width: 100, child: Row(children: [
            Text('${t.confidence.toStringAsFixed(1)}%', style: GoogleFonts.inter(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: t.confidence < 35 ? GeoColors.danger : GeoColors.warning)),
          ])),
          SizedBox(width: 90, child: Text(t.severity,
              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: sevColor))),
          SizedBox(width: 100, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(GeoRadius.full)),
              child: Text(t.status, style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w700, color: statusFg)))),
          SizedBox(width: 100, child: Row(children: [
            GestureDetector(
                onTap: () => setState(() => _selected = t),
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                        color: GeoColors.primary, borderRadius: BorderRadius.circular(GeoRadius.sm)),
                    child: Text('🔍 Track', style: GoogleFonts.inter(
                        fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)))),
            const SizedBox(width: 6),
            GestureDetector(
                onTap: () => setState(() {
                  final idx = _threats.indexOf(t);
                  if (idx >= 0) {
                    _threats[idx] = _ThreatItem(
                      icon: t.icon, title: t.title, type: t.type, gate: t.gate,
                      severity: t.severity, status: 'Resolved',
                      time: t.time, confidence: t.confidence, camera: t.camera);
                  }
                }),
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                        color: GeoColors.successGhost, borderRadius: BorderRadius.circular(GeoRadius.sm),
                        border: Border.all(color: GeoColors.success.withOpacity(.3))),
                    child: Text('✓', style: GoogleFonts.inter(
                        fontSize: 11, fontWeight: FontWeight.w700, color: GeoColors.success)))),
          ])),
        ]),
      ),
    );
  }

  // ── Detail panel ──────────────────────────────────────────────────────────
  Widget _buildDetailPanel(ThemeNotifier theme) {
    final t = _selected!;
    return Container(
      width: 520, color: theme.bgCard,
      child: Column(children: [
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.border))),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t.icon} ${t.type}', style: GoogleFonts.inter(
                    fontSize: 16, fontWeight: FontWeight.w800, color: theme.textPrimary)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: GeoColors.primaryGhost, borderRadius: BorderRadius.circular(GeoRadius.full)),
                  child: Text('🧠 Detected by InsightFace buffalo_l',
                      style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: GeoColors.primary))),
              ])),
              GestureDetector(
                  onTap: () => setState(() => _selected = null),
                  child: Container(width: 30, height: 30,
                      decoration: BoxDecoration(color: theme.bgBadge, shape: BoxShape.circle),
                      child: Center(child: Text('✕',
                          style: GoogleFonts.inter(fontSize: 16, color: theme.textPrimary))))),
            ])),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sec(theme, 'INCIDENT INFORMATION'),
            _row(theme, 'Location',         '📍 ${t.gate}'),
            _row(theme, 'Camera',           t.camera),
            _row(theme, 'Time Detected',
                '${t.time.hour.toString().padLeft(2,"0")}:${t.time.minute.toString().padLeft(2,"0")}'),
            _row(theme, 'Severity',         t.severity),
            _row(theme, 'Confidence',       '${t.confidence.toStringAsFixed(1)}%'),
            _row(theme, 'Recognition',      'InsightFace (cosine similarity)'),
            _row(theme, 'Threshold',        '0.45 — Not matched'),
            _row(theme, 'Verified Status',  '⏳ Pending Verification'),
            _row(theme, 'Assigned Guard',   '${_guards[0]['name']} · +91 98001 11111'),
            const SizedBox(height: 20),
            _sec(theme, '📍 THREAT LOCATION MAP'),
            Container(
                height: 200,
                decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(GeoRadius.md),
                    border: Border.all(color: theme.border)),
                child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('🗺️', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 8),
                  Text('Map: ${t.gate}', style: GoogleFonts.inter(fontSize: 13, color: Colors.white70)),
                  const SizedBox(height: 4),
                  Text('Lat: 12.91°N  Lng: 77.52°E',
                      style: GoogleFonts.inter(fontSize: 11, color: Colors.white38)),
                ]))),
            const SizedBox(height: 20),
            _sec(theme, '👮 NEARBY SECURITY GUARDS'),
            ..._guards.map((g) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Container(
                      width: 36, height: 36,
                      decoration: const BoxDecoration(shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [Color(0xFF1D4ED8), Color(0xFF1E3A8A)])),
                      child: Center(child: Text(g['init']!, style: GoogleFonts.inter(
                          fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${g['name']} ${g['id']}', style: GoogleFonts.inter(
                        fontSize: 13, fontWeight: FontWeight.w600, color: theme.textPrimary)),
                    Text('📍 ${g['zone']}', style: GoogleFonts.inter(fontSize: 11, color: theme.textTertiary)),
                  ])),
                  Text('🏃 ${g['eta']}', style: GoogleFonts.inter(
                      fontSize: 12, fontWeight: FontWeight.w700, color: GeoColors.success)),
                ]))),
          ]),
        )),
      ]),
    );
  }

  Widget _sec(ThemeNotifier theme, String title) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title, style: GoogleFonts.inter(
          fontSize: 11, fontWeight: FontWeight.w700,
          color: theme.textTertiary, letterSpacing: .8)));

  Widget _row(ThemeNotifier theme, String key, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(key, style: GoogleFonts.inter(fontSize: 12, color: theme.textTertiary)),
        Text(value, style: GoogleFonts.inter(
            fontSize: 12, fontWeight: FontWeight.w600, color: theme.textPrimary)),
      ]));

  Widget _topBtn(String label, ThemeNotifier theme) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
          color: theme.bgCard, border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(GeoRadius.sm)),
      child: Text(label, style: GoogleFonts.inter(
          fontSize: 12, fontWeight: FontWeight.w500, color: theme.textSecondary)));
}

// ─────────────────────────────────────────────────────────────────────────────
class _ThreatItem {
  final String icon, title, type, gate, severity, status, camera;
  final DateTime time;
  final double confidence;
  const _ThreatItem({
    required this.icon, required this.title, required this.type,
    required this.gate, required this.severity, required this.status,
    required this.time, required this.confidence, required this.camera,
  });
}

// ── Pie chart painter ─────────────────────────────────────────────────────────
class _PiePainter extends CustomPainter {
  final List<dynamic> data;
  const _PiePainter(this.data);

  Color _hexColor(String hex) {
    try { return Color(int.parse(hex.trim().replaceAll('#', '0xFF'))); }
    catch (_) { return Colors.grey; }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final total = data.fold<int>(0, (s, d) => s + (d[2] as int));
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2 - 4;
    double start = -3.14159 / 2;
    for (final d in data) {
      final sweep = (d[2] as int) / total * 2 * 3.14159;
      canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
          start, sweep, true, Paint()..color = _hexColor(d[1] as String));
      start += sweep;
    }
    canvas.drawCircle(Offset(cx, cy), r * 0.56,
        Paint()..color = const Color(0xFF1A1A1A));
  }

  @override bool shouldRepaint(_) => false;
}
