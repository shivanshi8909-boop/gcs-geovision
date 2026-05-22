import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Response from /recognize
class RecognizeResult {
  final bool matched;
  final String? userId;
  final String? name;
  final String? dept;
  final String? studentId;
  final double? confidence;
  final int faceCount;
  final String? eventType; // 'entry' | 'threat' | null
  final List<double>? bbox; // [x1,y1,x2,y2] normalised 0-1

  const RecognizeResult({
    required this.matched,
    this.userId,
    this.name,
    this.dept,
    this.studentId,
    this.confidence,
    required this.faceCount,
    this.eventType,
    this.bbox,
  });

  factory RecognizeResult.fromJson(Map<String, dynamic> j) => RecognizeResult(
        matched: j['matched'] as bool? ?? false,
        userId: j['user_id'] as String?,
        name: j['name'] as String?,
        dept: j['dept'] as String?,
        studentId: j['student_id'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble(),
        faceCount: j['face_count'] as int? ?? 0,
        eventType: j['event_type'] as String?,
        bbox: (j['bbox'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
      );
}

/// SSE event pushed by face_server
class FaceServerEvent {
  final String type; // 'recognition' | 'enrolled' | 'login' | 'cctv_alert'
  final Map<String, dynamic> data;
  final DateTime ts;

  const FaceServerEvent({required this.type, required this.data, required this.ts});

  factory FaceServerEvent.fromJson(Map<String, dynamic> j) => FaceServerEvent(
        type: j['type'] as String? ?? 'unknown',
        data: j['data'] as Map<String, dynamic>? ?? {},
        ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
      );

  /// True when this is an unrecognised-face threat event
  bool get isThreat =>
      (data['event_type'] as String?) == 'threat' ||
      type == 'cctv_alert';

  String get camera => data['camera'] as String? ?? 'Unknown Camera';
  double get confidence => (data['confidence'] as num?)?.toDouble() ?? 0;
}

/// Singleton service for GCS-GeoVision Face Server (port 5002)
class FaceServerService extends ChangeNotifier {
  // ── Config ──────────────────────────────────────────────────────────────
  static const String _base = 'http://localhost:5002';
  static const Duration _timeout = Duration(seconds: 20);

  // ── SSE state ───────────────────────────────────────────────────────────
  StreamSubscription<String>? _sseSub;
  final List<FaceServerEvent> _events = [];
  List<FaceServerEvent> get events => List.unmodifiable(_events);

  bool _sseConnected = false;
  bool get sseConnected => _sseConnected;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Start listening to SSE /events from the face server.
  void startSSE() {
    if (_sseSub != null) return; // already running
    _connectSSE();
  }

  void _connectSSE() {
    final client = http.Client();
    final req = http.Request('GET', Uri.parse('$_base/events'));
    req.headers['Accept'] = 'text/event-stream';
    req.headers['Cache-Control'] = 'no-cache';

    client.send(req).then((res) {
      _sseConnected = true;
      notifyListeners();

      _sseSub = res.stream
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data:'))
          .map((line) => line.substring(5).trim())
          .where((raw) => raw.isNotEmpty && raw != ':heartbeat')
          .listen(
        (raw) {
          try {
            final j = jsonDecode(raw) as Map<String, dynamic>;
            // Skip the initial 'connected' ping
            if (j['type'] == 'connected') return;
            final evt = FaceServerEvent.fromJson(j);
            _events.insert(0, evt);
            if (_events.length > 100) _events.removeLast();
            notifyListeners();
          } catch (e) {
            debugPrint('[FaceSSE] parse error: $e  raw=$raw');
          }
        },
        onError: (e) {
          debugPrint('[FaceSSE] error: $e');
          _sseConnected = false;
          notifyListeners();
          _sseSub = null;
          // Retry after 5 s
          Future.delayed(const Duration(seconds: 5), _connectSSE);
        },
        onDone: () {
          debugPrint('[FaceSSE] connection closed — retrying');
          _sseConnected = false;
          notifyListeners();
          _sseSub = null;
          Future.delayed(const Duration(seconds: 5), _connectSSE);
        },
        cancelOnError: false,
      );
    }).catchError((e) {
      debugPrint('[FaceSSE] connect failed: $e');
      _sseConnected = false;
      notifyListeners();
      Future.delayed(const Duration(seconds: 5), _connectSSE);
    });
  }

  void stopSSE() {
    _sseSub?.cancel();
    _sseSub = null;
    _sseConnected = false;
    notifyListeners();
  }

  // ── Enroll ───────────────────────────────────────────────────────────────

  /// Send up to 5 base64 JPEG frames to /enroll.
  /// [frames] — list of "data:image/jpeg;base64,..." or raw base64 strings.
  Future<Map<String, dynamic>> enroll({
    required List<String> frames,
    required String name,
    required String email,
    String dept = '',
    String studentId = '',
  }) async {
    final body = jsonEncode({
      'frames': frames,
      'name': name,
      'email': email,
      'dept': dept,
      'student_id': studentId,
    });
    final res = await http
        .post(
          Uri.parse('$_base/enroll'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(_timeout);

    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(j['detail'] ?? 'Enroll failed (${res.statusCode})');
    }
    return j;
  }

  // ── Recognize ────────────────────────────────────────────────────────────

  /// Send one base64 JPEG frame to /recognize.
  Future<RecognizeResult> recognize({
    required String frame,
    String camera = 'Flutter App',
  }) async {
    final body = jsonEncode({'frame': frame, 'camera': camera});
    final res = await http
        .post(
          Uri.parse('$_base/recognize'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception('Recognize failed (${res.statusCode})');
    }
    return RecognizeResult.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  // ── Verify Login ─────────────────────────────────────────────────────────

  /// Verify that a captured frame matches the enrolled face for [email].
  Future<Map<String, dynamic>> verifyLogin({
    required String frame,
    required String email,
  }) async {
    final body = jsonEncode({'frame': frame, 'email': email});
    final res = await http
        .post(
          Uri.parse('$_base/verify-login'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception('Verify-login failed (${res.statusCode})');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Stats / Alerts ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> fetchStats() async {
    final res = await http
        .get(Uri.parse('$_base/face-db-stats'))
        .timeout(_timeout);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchCctvAlerts({int limit = 50}) async {
    final res = await http
        .get(Uri.parse('$_base/cctv-alerts?limit=$limit'))
        .timeout(_timeout);
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (j['alerts'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Convenience: get only threat events from the local SSE buffer
  List<FaceServerEvent> get threatEvents =>
      _events.where((e) => e.isThreat).toList();

  @override
  void dispose() {
    stopSSE();
    super.dispose();
  }
}
