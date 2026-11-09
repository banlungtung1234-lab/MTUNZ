import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class RoomInvite {
  const RoomInvite({required this.code, required this.pin, required this.expiresInSeconds});
  final String code;
  final String pin;
  final int expiresInSeconds;
}

class JoinInfo {
  const JoinInfo({
    required this.peerToken,
    required this.peers,
    this.iceServers = const [],
  });

  final String peerToken;
  final List<Map<String, dynamic>> peers;
  final List<Map<String, dynamic>> iceServers;
}

class SignalingHttpException implements Exception {
  const SignalingHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'Máy chủ trả về $statusCode: $message';
}

class SignalingClient {
  SignalingClient({required this.serverUrl, required this.deviceName})
      : peerId = _randomId();

  final String serverUrl;
  final String deviceName;
  final String peerId;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  String? roomCode;
  String? _peerToken;
  bool _polling = false;
  bool _closed = false;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(serverUrl.trim());
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
  }

  Future<RoomInvite> createRoom() async {
    final response = await _request('POST', '/api/rooms', body: const {});
    final code = response['code'];
    final pin = response['joinPin'];
    if (code is! String || !RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(code) ||
        pin is! String || !RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const FormatException('Máy chủ trả về mã phòng không hợp lệ.');
    }
    return RoomInvite(
      code: code,
      pin: pin,
      expiresInSeconds: response['expiresInSeconds'] as int? ?? 900,
    );
  }

  Future<JoinInfo> joinRoom(String code, String pin) async {
    final normalizedCode = code.trim().toUpperCase();
    final normalizedPin = pin.trim();
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(normalizedCode) ||
        !RegExp(r'^\d{6}$').hasMatch(normalizedPin)) {
      throw const FormatException('Mã phòng hoặc PIN không đúng định dạng.');
    }
    final response = await _request(
      'POST',
      '/api/rooms/$normalizedCode/join',
      body: {'peerId': peerId, 'name': deviceName, 'joinPin': normalizedPin},
    );
    final token = response['peerToken'];
    if (token is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(token)) {
      throw const FormatException('Máy chủ trả về mã xác thực thiết bị không hợp lệ.');
    }
    roomCode = normalizedCode;
    _peerToken = token;
    final rawPeers = response['peers'];
    final peers = rawPeers is List
        ? rawPeers.whereType<Map<String, dynamic>>().toList(growable: false)
        : <Map<String, dynamic>>[];
    final iceServers = _parseIceServers(response['iceServers']);
    unawaited(_startPolling());
    return JoinInfo(peerToken: token, peers: peers, iceServers: iceServers);
  }

  List<Map<String, dynamic>> _parseIceServers(Object? raw) {
    if (raw is! List) return const [];
    final parsed = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final value = Map<String, dynamic>.from(item);
      final rawUrls = value['urls'];
      final urls = rawUrls is String
          ? <String>[rawUrls]
          : rawUrls is List
              ? rawUrls.whereType<String>().toList(growable: false)
              : const <String>[];
      final validUrls = urls.where((url) {
        final normalized = url.trim().toLowerCase();
        return normalized.startsWith('stun:') ||
            normalized.startsWith('stuns:') ||
            normalized.startsWith('turn:') ||
            normalized.startsWith('turns:');
      }).toList(growable: false);
      if (validUrls.isEmpty) continue;
      final server = <String, dynamic>{'urls': validUrls};
      final username = value['username'];
      final credential = value['credential'];
      if (username is String && username.isNotEmpty &&
          credential is String && credential.isNotEmpty) {
        server['username'] = username;
        server['credential'] = credential;
      }
      parsed.add(server);
    }
    return parsed;
  }

  Future<void> sendSignal(String to, String type, Map<String, dynamic> data) async {
    final code = roomCode;
    final token = _peerToken;
    if (code == null || token == null) throw StateError('Chưa tham gia phòng.');
    final payload = {'type': type, 'from': peerId, 'to': to, 'data': data};
    for (var attempt = 0; ; attempt++) {
      try {
        await _request(
          'POST',
          '/api/rooms/$code/signal',
          body: payload,
          token: token,
        );
        return;
      } on SignalingHttpException catch (error) {
        if (error.statusCode != 503 || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 180 * (attempt + 1)));
      }
    }
  }

  Future<void> leave() async {
    final code = roomCode;
    final token = _peerToken;
    _closed = true;
    if (code != null && token != null) {
      try {
        await _request(
          'POST',
          '/api/rooms/$code/leave',
          query: {'peerId': peerId},
          body: const {},
          token: token,
        );
      } catch (_) {
        // A room can expire or the network may already be gone.
      }
    }
    roomCode = null;
    _peerToken = null;
    _client.close(force: true);
    if (!_events.isClosed) await _events.close();
  }

  int _pollFailures = 0;

  Duration _nextPollingDelay() {
    _pollFailures = (_pollFailures + 1).clamp(1, 4).toInt();
    return Duration(milliseconds: 500 * (1 << (_pollFailures - 1)));
  }

  Future<void> _startPolling() async {
    if (_polling || roomCode == null || _peerToken == null) return;
    _polling = true;
    var warningEmitted = false;
    try {
      while (!_closed && roomCode != null && _peerToken != null) {
        try {
          final code = roomCode!;
          final token = _peerToken!;
          final uri = _uri('/api/rooms/$code/events', {'peerId': peerId});
          final request = await _client.getUrl(uri);
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          final response = await request.close().timeout(const Duration(seconds: 25));
          final text = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            final recovered = warningEmitted;
            warningEmitted = false;
            _pollFailures = 0;
            if (recovered && !_events.isClosed) {
              _events.add({'type': 'connection-restored'});
            }
            if (text.isNotEmpty) {
              final decoded = jsonDecode(text);
              if (decoded is List) {
                for (final item in decoded) {
                  if (item is Map<String, dynamic> && !_events.isClosed) {
                    _events.add(item);
                  }
                }
              }
            }
          } else if (response.statusCode == 404) {
            if (!_events.isClosed) _events.add({'type': 'room-expired'});
            break;
          } else if (response.statusCode >= 400 &&
              response.statusCode < 500 &&
              response.statusCode != 408 &&
              response.statusCode != 429) {
            if (!_events.isClosed) {
              _events.add({
                'type': 'session-error',
                'statusCode': response.statusCode,
                'message': text.trim(),
              });
            }
            break;
          } else {
            if (!_closed && !_events.isClosed && !warningEmitted) {
              _events.add({
                'type': 'connection-warning',
                'message': 'Máy chủ đang tạm thời không phản hồi (${response.statusCode}).',
              });
              warningEmitted = true;
            }
            await Future<void>.delayed(_nextPollingDelay());
          }
        } catch (error) {
          if (_closed) break;
          if (!_events.isClosed && !warningEmitted) {
            _events.add({'type': 'connection-warning', 'message': '$error'});
            warningEmitted = true;
          }
          await Future<void>.delayed(_nextPollingDelay());
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    String? token,
  }) async {
    final uri = _uri(path, query);
    final request = await _client.openUrl(method, uri).timeout(const Duration(seconds: 10));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final payload = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SignalingHttpException(response.statusCode, payload.trim());
    }
    if (payload.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
