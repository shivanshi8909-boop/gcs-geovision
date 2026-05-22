import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/face_server_service.dart';
import '../../widgets/common_widgets.dart';
import 'profile_screen.dart'; // UserShell is defined here

// ─────────────────────────────────────────────────────────────────────────────
/// Face Enrolment screen.
///
/// Uses the browser's getUserMedia API (via package:web + dart:js_interop)
/// to capture 3 real frames, then POSTs them as base64 JPEGs to the
/// InsightFace backend at localhost:5002/enroll.
// ─────────────────────────────────────────────────────────────────────────────
class FaceEnrolScreen extends StatefulWidget {
  final String mode; // 'register' | 'update'
  const FaceEnrolScreen({super.key, this.mode = 'update'});
  @override
  State<FaceEnrolScreen> createState() => _FaceEnrolScreenState();
}

class _FaceEnrolScreenState extends State<FaceEnrolScreen>
    with SingleTickerProviderStateMixin {
  // ── Phase ─────────────────────────────────────────────────────────────────
  _Phase _phase = _Phase.idle;
  String? _errorMsg;
  int _capturesDone = 0;
  final List<String> _frames = [];

  // ── Animation ─────────────────────────────────────────────────────────────
  late AnimationController _pulse;

  // ── Camera / DOM ──────────────────────────────────────────────────────────
  web.HTMLVideoElement? _video;
  web.MediaStream? _stream;
  bool _cameraReady = false;

  /// Unique view-type id so Flutter renders this instance's video element
  late final String _viewId;

  @override
  void initState() {
    super.initState();
    _viewId = 'face-enrol-video-${identityHashCode(this)}';
    _pulse = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _initCamera();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _stopCamera();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Camera
  // ─────────────────────────────────────────────────────────────────────────

  void _initCamera() async {
    try {
      final video = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true;
      video.style
        ..setProperty('width', '100%')
        ..setProperty('height', '100%')
        ..setProperty('object-fit', 'cover')
        ..setProperty('transform', 'scaleX(-1)'); // mirror for natural feel

      // Register Flutter platform view (once per unique viewId)
      ui_web.platformViewRegistry.registerViewFactory(
        _viewId,
        (_) => video,
        isVisible: true,
      );

      _video = video;

      // Request camera via getUserMedia
      final mediaDevices = web.window.navigator.mediaDevices;
      if (mediaDevices == null) throw Exception('Camera not supported on this browser');

      // Build constraints using package:web typed API
      final constraints = web.MediaStreamConstraints(
        video: true.toJS,  // basic: any camera; browser will use default/user-facing
        audio: false.toJS,
      );

      final stream = await mediaDevices.getUserMedia(constraints).toDart;

      _stream = stream;
      video.srcObject = stream;

      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = 'Camera error: ${e.toString().replaceFirst("Exception: ", "")}.\n'
              'Please allow camera access and refresh.';
          _phase = _Phase.error;
        });
      }
    }
  }

  void _stopCamera() {
    final tracks = _stream?.getTracks().toDart;
    if (tracks != null) {
      for (final track in tracks) {
        track.stop();
      }
    }
    _video?.srcObject = null;
    _stream = null;
  }

  /// Grab the current video frame as a base64 JPEG data-URL.
  String _captureFrame() {
    final v = _video!;
    final w = v.videoWidth == 0 ? 640 : v.videoWidth;
    final h = v.videoHeight == 0 ? 480 : v.videoHeight;

    final canvas = web.HTMLCanvasElement()
      ..width = w
      ..height = h;
    // getContext returns JSObject — cast to 2D context for drawImage
    final ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    ctx.drawImage(v, 0, 0);
    return canvas.toDataURL('image/jpeg', 0.85.toJS);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Capture + Enrol pipeline
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startCapture() async {
    if (!_cameraReady || _video == null) {
      setState(() => _errorMsg = 'Camera not ready. Refresh the page.');
      return;
    }

    setState(() {
      _phase        = _Phase.capturing;
      _capturesDone = 0;
      _frames.clear();
      _errorMsg     = null;
    });

    // Capture 3 frames, 1.5 s apart
    for (int i = 1; i <= 3; i++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      _frames.add(_captureFrame());
      setState(() => _capturesDone = i);
    }

    // Send to InsightFace backend
    setState(() => _phase = _Phase.processing);

    try {
      final auth = context.read<AuthService>();
      final fr   = context.read<FaceServerService>();
      final user = auth.currentUser;

      if (user == null) throw Exception('Not logged in');

      await fr.enroll(
        frames:    _frames,
        name:      user.name,
        email:     user.email,
        dept:      user.dept ?? '',
        studentId: user.studentId ?? '',
      );

      await auth.updateProfile(user.copyWith(faceEnrolled: true));
      _stopCamera();

      if (mounted) setState(() => _phase = _Phase.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase    = _Phase.idle;
          _errorMsg = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme      = context.watch<ThemeNotifier>();
    final isRegister = widget.mode == 'register';

    return UserShell(
      activeIndex: 2,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          const SizedBox(height: 12),

          Text('🤳 Face Enrolment', style: GoogleFonts.inter(
              fontSize: 20, fontWeight: FontWeight.w800, color: theme.textPrimary)),
          const SizedBox(height: 4),
          Text(
            isRegister
                ? 'Complete your registration by enrolling your face'
                : 'Update your face data for campus entry recognition',
            style: GoogleFonts.inter(fontSize: 13, color: theme.textTertiary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),

          if (_phase == _Phase.done)
            _buildSuccess(theme)
          else ...[
            _buildViewfinder(theme),
            const SizedBox(height: 20),
            if (_errorMsg != null) _buildErrorBanner(theme),
            if (_phase == _Phase.idle)   _buildInstructions(theme),
            if (_phase == _Phase.capturing || _phase == _Phase.processing)
              _buildProgressSteps(theme),
          ],
        ]),
      ),
    );
  }

  // ── Viewfinder ────────────────────────────────────────────────────────────
  Widget _buildViewfinder(ThemeNotifier theme) {
    final active = _phase == _Phase.capturing || _phase == _Phase.processing;
    final borderColor = active
        ? GeoColors.success.withValues(alpha: 0.85)
        : GeoColors.primary.withValues(alpha: 0.5);

    return Container(
      width: 320, height: 260,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(GeoRadius.lg),
        border: Border.all(color: borderColor, width: 2),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(children: [
        // ── Live camera feed ──
        if (_cameraReady)
          Positioned.fill(child: HtmlElementView(viewType: _viewId))
        else if (_phase == _Phase.error)
          const Positioned.fill(child: Center(
              child: Text('📵', style: TextStyle(fontSize: 40))))
        else
          const Positioned.fill(child: Center(child: CircularProgressIndicator())),

        // ── Grid overlay ──
        Positioned.fill(child: CustomPaint(painter: _GridPainter(active: active))),

        // ── Corner brackets ──
        ..._corners(active: active),

        // ── Face oval guide ──
        Center(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Container(
              width: 130, height: 155,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(80),
                border: Border.all(
                  color: active
                      ? GeoColors.success.withValues(alpha: 0.4 + _pulse.value * 0.3)
                      : GeoColors.primary.withValues(alpha: 0.3 + _pulse.value * 0.2),
                  width: 2,
                ),
              ),
            ),
          ),
        ),

        // ── Bottom label bar ──
        Positioned(bottom: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Color(0xEE000000), Colors.transparent],
            )),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (active) ...[const LiveDot(), const SizedBox(width: 6)],
              Text(
                _phase == _Phase.processing
                    ? '⚡ Running InsightFace…'
                    : active
                        ? '📸 $_capturesDone / 3 captured'
                        : _cameraReady
                            ? '🎯 Align face in oval'
                            : '📷 Starting camera…',
                style: GoogleFonts.inter(
                    fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ]),
          ),
        ),

        // ── Capture count badge ──
        if (active && _capturesDone > 0)
          Positioned(top: 10, right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: GeoColors.success.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(GeoRadius.sm),
              ),
              child: Text('✓ $_capturesDone',
                  style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
            )),
      ]),
    );
  }

  // ── Progress steps ────────────────────────────────────────────────────────
  Widget _buildProgressSteps(ThemeNotifier theme) {
    final labels = [
      'Taking photo 1 of 3…',
      'Taking photo 2 of 3…',
      'Taking photo 3 of 3…',
      'Running InsightFace AI…',
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.bgCard,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(GeoRadius.lg),
      ),
      child: Column(children: List.generate(4, (i) {
        final done   = i < _capturesDone || (_phase == _Phase.processing && i < 3);
        final active = _phase == _Phase.processing ? i == 3 : i == _capturesDone;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? GeoColors.success : active ? GeoColors.primary : theme.bgBadge,
                border: Border.all(
                    color: done ? GeoColors.success : active ? GeoColors.primary : theme.border),
              ),
              child: Center(child: done
                  ? const Text('✓', style: TextStyle(
                      fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700))
                  : active
                      ? const SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('${i + 1}', style: GoogleFonts.inter(
                          fontSize: 12, color: theme.textTertiary))),
            ),
            const SizedBox(width: 14),
            Text(labels[i], style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: done ? GeoColors.success : active ? theme.textPrimary : theme.textTertiary)),
          ]),
        );
      })),
    );
  }

  // ── Error banner ──────────────────────────────────────────────────────────
  Widget _buildErrorBanner(ThemeNotifier theme) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: GeoColors.dangerGhost,
      border: Border.all(color: GeoColors.danger.withValues(alpha: 0.3)),
      borderRadius: BorderRadius.circular(GeoRadius.md),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('⚠️', style: TextStyle(fontSize: 18)),
      const SizedBox(width: 10),
      Expanded(child: Text(_errorMsg!,
          style: GoogleFonts.inter(fontSize: 13, color: GeoColors.danger, height: 1.4))),
    ]),
  );

  // ── Instructions + Start button ────────────────────────────────────────────
  Widget _buildInstructions(ThemeNotifier theme) => Column(children: [
    Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.bgCard,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(GeoRadius.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('📋 Instructions', style: GoogleFonts.inter(
            fontSize: 14, fontWeight: FontWeight.w700, color: theme.textPrimary)),
        const SizedBox(height: 14),
        ...[
          '✅ Ensure good, even lighting on your face',
          '✅ Remove sunglasses or heavy accessories',
          '✅ Align your face inside the oval guide',
          '✅ Keep a neutral expression and stay still',
          '✅ 3 frames will be analysed by InsightFace (buffalo_l)',
        ].map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(s, style: GoogleFonts.inter(
                fontSize: 13, color: theme.textSecondary, height: 1.4)))),
      ]),
    ),
    const SizedBox(height: 20),
    SizedBox(width: double.infinity, child: ElevatedButton(
      onPressed: _cameraReady ? _startCapture : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: GeoColors.primary, foregroundColor: Colors.white,
        disabledBackgroundColor: GeoColors.primary.withValues(alpha: 0.4),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GeoRadius.md)),
      ),
      child: Text(
        _cameraReady ? '🤳 Start Face Capture' : '📷 Waiting for camera…',
        style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800)),
    )),
    const SizedBox(height: 80),
  ]);

  // ── Success ───────────────────────────────────────────────────────────────
  Widget _buildSuccess(ThemeNotifier theme) => Column(children: [
    Container(
      width: 120, height: 120,
      decoration: const BoxDecoration(shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF22C55E), Color(0xFF15803D)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        )),
      child: const Center(child: Text('✓', style: TextStyle(
          fontSize: 52, color: Colors.white, fontWeight: FontWeight.w900))),
    ),
    const SizedBox(height: 24),
    Text('Face Enrolled!', style: GoogleFonts.inter(
        fontSize: 22, fontWeight: FontWeight.w800, color: GeoColors.success)),
    const SizedBox(height: 8),
    Text(
      '3 frames processed by InsightFace buffalo_l.\nYou can now use facial recognition at campus gates.',
      style: GoogleFonts.inter(fontSize: 14, color: theme.textSecondary, height: 1.6),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 28),
    Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: GeoColors.successGhost,
        border: Border.all(color: GeoColors.success.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(GeoRadius.lg),
      ),
      child: Column(children: [
        _successRow(theme, '📸', '3 frames captured', 'Multi-angle coverage'),
        const SizedBox(height: 12),
        _successRow(theme, '🧠', 'InsightFace buffalo_l', '512-dim embedding stored'),
        const SizedBox(height: 12),
        _successRow(theme, '🔒', 'Cosine-similarity matching', 'Threshold ≥ 0.45'),
      ]),
    ),
    const SizedBox(height: 28),
    SizedBox(width: double.infinity, child: ElevatedButton(
      onPressed: () => context.go('/user/profile'),
      style: ElevatedButton.styleFrom(
        backgroundColor: GeoColors.primary, foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GeoRadius.md)),
      ),
      child: Text('← Back to Profile', style: GoogleFonts.inter(
          fontSize: 15, fontWeight: FontWeight.w800)),
    )),
    const SizedBox(height: 80),
  ]);

  Widget _successRow(ThemeNotifier theme, String icon, String title, String sub) =>
      Row(children: [
        Text(icon, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.inter(
              fontSize: 13, fontWeight: FontWeight.w700, color: theme.textPrimary)),
          Text(sub, style: GoogleFonts.inter(fontSize: 12, color: theme.textSecondary)),
        ]),
      ]);

  // ── Corner bracket helpers ─────────────────────────────────────────────────
  List<Widget> _corners({required bool active}) {
    final c = active ? GeoColors.success : GeoColors.primary;
    return [
      Positioned(top: 12, left: 12,   child: _corner(c)),
      Positioned(top: 12, right: 12,  child: _corner(c, flipH: true)),
      Positioned(bottom: 12, left: 12,  child: _corner(c, flipV: true)),
      Positioned(bottom: 12, right: 12, child: _corner(c, flipH: true, flipV: true)),
    ];
  }

  Widget _corner(Color c, {bool flipH = false, bool flipV = false}) =>
      Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(flipH ? -1 : 1, flipV ? -1 : 1, 1),
        child: SizedBox(width: 18, height: 18,
            child: CustomPaint(painter: _CornerPainter(c))));
}

// ─────────────────────────────────────────────────────────────────────────────
enum _Phase { idle, capturing, processing, done, error }

// ── Painters ─────────────────────────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  final bool active;
  const _GridPainter({required this.active});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (active ? Colors.green : GeoColors.primary).withValues(alpha: 0.06)
      ..strokeWidth = .5;
    const step = 32.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override bool shouldRepaint(_GridPainter o) => o.active != active;
}

class _CornerPainter extends CustomPainter {
  final Color color;
  const _CornerPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), p);
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
  }
  @override bool shouldRepaint(_) => false;
}
