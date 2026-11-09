import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Signaling Core embedded in the MTUNZ Flutter process on Windows and Android.
///
/// The HTTP routes intentionally match the optional Go signaling service so
/// the WebRTC client can use either the embedded LAN Core or a remote service.
class EmbeddedSignalingServer {
  static const int _maxRoomPeers = 3;
  static const int _maxActiveRooms = 64;
  static const int _maxBodyBytes = 32 * 1024;
  static const int _maxQueue = 32;
  static const int _maxRateEntries = 10000;
  static const Duration _roomTtl = Duration(minutes: 15);
  static const Duration _peerIdleTtl = Duration(seconds: 90);
  static const Duration _pollTimeout = Duration(seconds: 20);

  final Map<String, _Room> _rooms = <String, _Room>{};
  final Map<String, _RateEntry> _createRate = <String, _RateEntry>{};
  final Map<String, _RateEntry> _joinRate = <String, _RateEntry>{};
  final Random _random = Random.secure();

  HttpServer? _server;
  Timer? _cleanupTimer;
  bool _closing = false;

  bool get isRunning => _server != null && !_closing;
  int get port => _server?.port ?? 0;

  /// Local URL used by the app instance that owns this Core.
  Uri get localUri => Uri(scheme: 'http', host: '127.0.0.1', port: port);

  /// Starts the Core on all IPv4 interfaces.
  ///
  /// Port 8787 is preferred for LAN invitations. If another process already
  /// owns it, the OS assigns a free ephemeral port rather than failing.
  Future<void> start({int preferredPort = 0}) async {
    if (isRunning) return;
    _closing = false;

    HttpServer bound;
    try {
      bound = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
        shared: false,
      );
    } on SocketException {
      if (preferredPort == 0) rethrow;
      bound = await HttpServer.bind(
        InternetAddress.anyIPv4,
        0,
        shared: false,
      );
    }

    if (_closing) {
      await bound.close(force: true);
      return;
    }

    _server = bound;
    bound.listen(
      _handleRequest,
      onError: (_) {},
      cancelOnError: false,
    );
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _cleanupExpired(),
    );
  }

  Future<void> close() async {
    _closing = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    final server = _server;
    _server = null;

    for (final room in _rooms.values) {
      for (final peer in room.peers.values) {
        _finishPeer(peer);
      }
    }
    _rooms.clear();
    _createRate.clear();
    _joinRate.clear();

    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');

    try {
      final path = request.uri.path;
      final segments = request.uri.pathSegments;

      if (request.method == 'GET' && path == '/healthz') {
        await _writeJson(request.response, HttpStatus.ok, <String, Object>{
          'ok': true,
          'service': 'mtunz-embedded-core',
          'version': '0.4.0-dev',
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/rooms') {
        await _createRoom(request);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'rooms') {
        final code = segments[2].toUpperCase();
        final action = segments[3];

        if (action == 'join' && request.method == 'POST') {
          await _joinRoom(request, code);
          return;
        }
        if (action == 'events' && request.method == 'GET') {
          await _pollEvents(request, code);
          return;
        }
        if (action == 'signal' && request.method == 'POST') {
          await _sendSignal(request, code);
          return;
        }
        if (action == 'leave' && request.method == 'POST') {
          await _leaveRoom(request, code);
          return;
        }
      }

      await _writeText(request.response, HttpStatus.notFound, 'not found');
    } catch (error) {
      final status = error is _RequestTooLarge
          ? HttpStatus.requestEntityTooLarge
          : error is FormatException
              ? HttpStatus.badRequest
              : HttpStatus.internalServerError;
      final message = error is _RequestTooLarge
          ? 'request body too large'
          : error is FormatException
              ? 'invalid request'
              : 'internal Core error';

      // A peer may have disconnected after a response was committed. Attempt
      // one bounded error response, then close quietly if the socket is gone.
      try {
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.text
          ..write(message);
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _createRoom(HttpRequest request) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (!_allowAttempt(ip, _createRate, 6)) {
      await _writeText(
        request.response,
        HttpStatus.tooManyRequests,
        'too many room creation attempts; try again later',
      );
      return;
    }

    await _readJson(request);
    _cleanupExpired();

    if (_rooms.length >= _maxActiveRooms) {
      await _writeText(
        request.response,
        HttpStatus.serviceUnavailable,
        'server has reached its active room limit',
      );
      return;
    }

    var code = _randomCode(8);
    while (_rooms.containsKey(code)) {
      code = _randomCode(8);
    }

    final pin = _randomDigits(6);
    _rooms[code] = _Room(
      code: code,
      joinPin: pin,
      expiresAt: DateTime.now().add(_roomTtl),
    );

    await _writeJson(request.response, HttpStatus.created, <String, Object>{
      'code': code,
      'joinPin': pin,
      'expiresInSeconds': _roomTtl.inSeconds,
    });
  }

  Future<void> _joinRoom(HttpRequest request, String code) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (!_allowAttempt(ip, _joinRate, 12)) {
      await _writeText(
        request.response,
        HttpStatus.tooManyRequests,
        'too many invitation attempts; try again later',
      );
      return;
    }

    final body = await _readJson(request);
    if (body['peerId'] is! String ||
        body['joinPin'] is! String ||
        (body['name'] != null && body['name'] is! String)) {
      await _writeText(
        request.response,
        HttpStatus.badRequest,
        'invalid peerId, name or invitation PIN',
      );
      return;
    }

    final peerId = (body['peerId'] as String).trim();
    final rawName = (body['name'] as String? ?? '').trim();
    final pin = body['joinPin'] as String;

    if (peerId.length < 8 ||
        peerId.length > 80 ||
        !RegExp(r'^\d{6}$').hasMatch(pin)) {
      await _writeText(
        request.response,
        HttpStatus.badRequest,
        'invalid peerId or invitation PIN',
      );
      return;
    }

    final room = _rooms[code];
    if (room == null ||
        !DateTime.now().isBefore(room.expiresAt) ||
        !_constantTimeEquals(pin, room.joinPin)) {
      await _writeText(
        request.response,
        HttpStatus.notFound,
        'room not found or invitation PIN invalid',
      );
      return;
    }

    if (room.peers.containsKey(peerId)) {
      await _writeText(request.response, HttpStatus.conflict, 'peer already joined');
      return;
    }

    if (room.peers.length >= _maxRoomPeers) {
      await _writeText(
        request.response,
        HttpStatus.conflict,
        'room is full (maximum 3 devices)',
      );
      return;
    }

    if (room.peers.values.any((peer) => peer.events.length >= _maxQueue)) {
      await _writeText(
        request.response,
        HttpStatus.serviceUnavailable,
        'room signaling queue is busy; retry shortly',
      );
      return;
    }

    final existing = room.peers.values
        .map((peer) => <String, String>{
              'id': peer.id,
              'name': peer.name,
            })
        .toList(growable: false);

    final peer = _Peer(
      id: peerId,
      name: _limitName(rawName.isEmpty ? 'MTUNZ device' : rawName),
      token: _randomHex(32),
    );

    room.peers[peerId] = peer;
    for (final other in room.peers.values) {
      if (other.id != peerId) {
        _enqueue(other, <String, Object?>{
          'type': 'peer-joined',
          'peer': <String, String>{'id': peer.id, 'name': peer.name},
        });
      }
    }

    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'peers': existing,
      'peerToken': peer.token,
      // Public TURN credentials are supplied by an optional external service.
      'iceServers': const <Object>[],
    });
  }

  Future<void> _pollEvents(HttpRequest request, String code) async {
    final peerId = request.uri.queryParameters['peerId']?.trim() ?? '';
    if (peerId.isEmpty) {
      await _writeText(request.response, HttpStatus.badRequest, 'peerId required');
      return;
    }

    final room = _rooms[code];
    final peer = room?.peers[peerId];
    if (room == null || peer == null || !_authorized(request, peer)) {
      await _writeText(
        request.response,
        HttpStatus.notFound,
        'peer not joined or room expired',
      );
      return;
    }

    if (peer.polling) {
      await _writeText(
        request.response,
        HttpStatus.conflict,
        'a long-poll request is already active',
      );
      return;
    }

    peer.polling = true;
    peer.lastSeen = DateTime.now();
    try {
      if (peer.events.isEmpty && !peer.done.isCompleted) {
        final wake = Completer<void>();
        peer.waiter = wake;
        await Future.any<void>(<Future<void>>[
          wake.future,
          peer.done.future,
          Future<void>.delayed(_pollTimeout),
        ]);
      }

      if (peer.done.isCompleted) {
        await _writeText(
          request.response,
          HttpStatus.notFound,
          'peer session expired',
        );
        return;
      }

      peer.lastSeen = DateTime.now();
      final messages = <Map<String, Object?>>[];
      while (peer.events.isNotEmpty && messages.length < _maxQueue) {
        messages.add(peer.events.removeFirst());
      }
      await _writeJson(request.response, HttpStatus.ok, messages);
    } finally {
      peer.waiter = null;
      peer.polling = false;
    }
  }

  Future<void> _sendSignal(HttpRequest request, String code) async {
    final body = await _readJson(request);
    if (body['type'] is! String ||
        body['from'] is! String ||
        body['to'] is! String) {
      await _writeText(
        request.response,
        HttpStatus.badRequest,
        'valid sender, target and message type are required',
      );
      return;
    }

    final type = body['type'] as String;
    final from = body['from'] as String;
    final to = body['to'] as String;
    final data = body['data'];

    const supported = <String>{
      'offer',
      'answer',
      'candidate',
      'candidate-batch',
      'control-request',
      'control-grant',
      'control-revoke',
      'renegotiate-request',
    };

    if (from.length < 8 ||
        from.length > 80 ||
        to.length < 8 ||
        to.length > 80 ||
        from == to ||
        !supported.contains(type)) {
      await _writeText(
        request.response,
        HttpStatus.badRequest,
        'valid sender, target and message type are required',
      );
      return;
    }

    if (type == 'candidate-batch') {
      if (data is! Map || data['candidates'] is! List) {
        await _writeText(
          request.response,
          HttpStatus.badRequest,
          'invalid candidate batch',
        );
        return;
      }

      final candidates = data['candidates'] as List;
      final invalid = candidates.isEmpty ||
          candidates.length > 8 ||
          candidates.any(
            (item) =>
                item is! Map ||
                item['candidate'] is! String ||
                (item['candidate'] as String).isEmpty ||
                (item['candidate'] as String).length > 2048,
          );
      if (invalid) {
        await _writeText(
          request.response,
          HttpStatus.badRequest,
          'candidate batch must contain 1 to 8 valid candidates',
        );
        return;
      }
    }

    final room = _rooms[code];
    final sender = room?.peers[from];
    if (room == null || sender == null || !_authorized(request, sender)) {
      await _writeText(
        request.response,
        HttpStatus.notFound,
        'sender not joined or room expired',
      );
      return;
    }

    final target = room.peers[to];
    if (target == null) {
      await _writeText(request.response, HttpStatus.notFound, 'target peer not found');
      return;
    }

    if (!_enqueue(target, <String, Object?>{
      'type': type,
      'from': from,
      'to': to,
      if (data != null) 'data': data,
    })) {
      await _writeText(
        request.response,
        HttpStatus.serviceUnavailable,
        'target signaling queue is full; retry shortly',
      );
      return;
    }

    sender.lastSeen = DateTime.now();
    request.response.statusCode = HttpStatus.accepted;
    await request.response.close();
  }

  Future<void> _leaveRoom(HttpRequest request, String code) async {
    final peerId = request.uri.queryParameters['peerId']?.trim() ?? '';
    final room = _rooms[code];
    final peer = room?.peers[peerId];

    if (room == null || peer == null || !_authorized(request, peer)) {
      await _writeText(
        request.response,
        HttpStatus.notFound,
        'room or peer not found',
      );
      return;
    }

    _removePeer(room, peerId);
    if (room.peers.isEmpty) _rooms.remove(code);

    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > _maxBodyBytes) {
        throw const _RequestTooLarge();
      }
      bytes.addAll(chunk);
    }

    if (bytes.isEmpty) return <String, dynamic>{};

    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON object required');
    }
    return decoded;
  }

  bool _authorized(HttpRequest request, _Peer peer) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final supplied = header.startsWith('Bearer ')
        ? header.substring(7).trim()
        : '';
    return _constantTimeEquals(supplied, peer.token);
  }

  bool _constantTimeEquals(String leftValue, String rightValue) {
    final left = utf8.encode(leftValue);
    final right = utf8.encode(rightValue);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var index = 0; index < length; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      difference |= a ^ b;
    }
    return difference == 0;
  }

  bool _allowAttempt(
    String ip,
    Map<String, _RateEntry> entries,
    int limit,
  ) {
    final now = DateTime.now();
    var entry = entries[ip];

    if (entry == null || !now.isBefore(entry.resetAt)) {
      if (entry == null && entries.length >= _maxRateEntries) {
        entries.removeWhere((_, value) => !now.isBefore(value.resetAt));
        if (entries.length >= _maxRateEntries) return false;
      }
      entry = _RateEntry(resetAt: now.add(const Duration(minutes: 5)));
    }

    entry.count++;
    entries[ip] = entry;
    return entry.count <= limit;
  }

  bool _enqueue(_Peer peer, Map<String, Object?> event) {
    if (peer.done.isCompleted || peer.events.length >= _maxQueue) return false;
    peer.events.addLast(event);

    final waiter = peer.waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    return true;
  }

  void _removePeer(_Room room, String peerId) {
    final peer = room.peers.remove(peerId);
    if (peer == null) return;

    _finishPeer(peer);
    for (final other in room.peers.values) {
      if (!_enqueue(other, <String, Object?>{
        'type': 'peer-left',
        'peerId': peerId,
      })) {
        if (other.events.isNotEmpty) other.events.removeFirst();
        _enqueue(other, <String, Object?>{
          'type': 'peer-left',
          'peerId': peerId,
        });
      }
    }
  }

  void _finishPeer(_Peer peer) {
    if (!peer.done.isCompleted) peer.done.complete();
    final waiter = peer.waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _cleanupExpired() {
    final now = DateTime.now();
    final expiredRooms = <String>[];

    for (final entry in _rooms.entries) {
      final room = entry.value;
      if (!now.isBefore(room.expiresAt)) {
        for (final peer in room.peers.values) {
          _finishPeer(peer);
        }
        expiredRooms.add(entry.key);
        continue;
      }

      final hadPeers = room.peers.isNotEmpty;
      final stalePeerIds = room.peers.values
          .where((peer) => now.difference(peer.lastSeen) > _peerIdleTtl)
          .map((peer) => peer.id)
          .toList(growable: false);

      for (final peerId in stalePeerIds) {
        _removePeer(room, peerId);
      }

      // Preserve empty invitations until their normal 15-minute expiry.
      if (hadPeers && room.peers.isEmpty) {
        expiredRooms.add(entry.key);
      }
    }

    for (final code in expiredRooms) {
      _rooms.remove(code);
    }
    _createRate.removeWhere((_, entry) => !now.isBefore(entry.resetAt));
    _joinRate.removeWhere((_, entry) => !now.isBefore(entry.resetAt));
  }

  String _randomCode(int length) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List<String>.generate(
      length,
      (_) => alphabet[_random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }

  String _randomDigits(int length) => List<String>.generate(
        length,
        (_) => _random.nextInt(10).toString(),
        growable: false,
      ).join();

  String _randomHex(int byteLength) {
    const alphabet = '0123456789abcdef';
    return List<String>.generate(
      byteLength * 2,
      (_) => alphabet[_random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }

  String _limitName(String value) {
    final runes = value.runes;
    if (runes.length <= 48) return value;
    return String.fromCharCodes(runes.take(48));
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Object body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _writeText(
    HttpResponse response,
    int status,
    String body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
    await response.close();
  }
}

class _Room {
  _Room({
    required this.code,
    required this.joinPin,
    required this.expiresAt,
  });

  final String code;
  final String joinPin;
  final DateTime expiresAt;
  final Map<String, _Peer> peers = <String, _Peer>{};
}

class _Peer {
  _Peer({
    required this.id,
    required this.name,
    required this.token,
  });

  final String id;
  final String name;
  final String token;
  final Queue<Map<String, Object?>> events = Queue<Map<String, Object?>>();
  final Completer<void> done = Completer<void>();
  Completer<void>? waiter;
  DateTime lastSeen = DateTime.now();
  bool polling = false;
}

class _RateEntry {
  _RateEntry({required this.resetAt});

  final DateTime resetAt;
  int count = 0;
}

class _RequestTooLarge implements Exception {
  const _RequestTooLarge();
}