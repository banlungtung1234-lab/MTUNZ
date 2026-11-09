import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// MTUNZ's embedded signaling Core.
///
/// It implements the same small HTTP contract as the optional Go signaling
/// service, but runs inside the Flutter process on both Windows and Android.
/// No external server executable or manually opened terminal is required for
/// trusted-LAN pairing.
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

  HttpServer? _httpServer;
  Timer? _cleanupTimer;
  bool _closing = false;

  bool get isRunning => _httpServer != null && !_closing;
  int get port => _httpServer?.port ?? 0;

  /// The loopback address used by this app instance to talk to its own Core.
  Uri get localUri => Uri(scheme: 'http', host: '127.0.0.1', port: port);

  Future<void> start({int preferredPort = 0}) async {
    if (isRunning) return;
    _closing = false;
    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
        shared: false,
      );
    } on SocketException {
      // A preferred port may already belong to another process. Use an
      // ephemeral port instead of failing startup or taking over that port.
      if (preferredPort == 0) rethrow;
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        0,
        shared: false,
      );
    }
    if (_closing) {
      await server.close(force: true);
      return;
    }
    _httpServer = server;
    server.listen(
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
    final server = _httpServer;
    _httpServer = null;
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
      ..set(HttpHeaders.xContentTypeOptionsHeader, 'nosniff')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final segments = request.uri.pathSegments;
      if (request.method == 'GET' &&
          request.uri.path == '/healthz') {
        _writeJson(request.response, HttpStatus.ok, <String, Object>{
          'ok': true,
          'service': 'mtunz-embedded-core',
          'version': '0.4.0-dev',
        });
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/rooms') {
        await _createRoom(request);
        return;
      }
      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'rooms') {
        final code = segments[2].toUpperCase();
        switch (segments[3]) {
          case 'join':
            if (request.method == 'POST') {
              await _joinRoom(request, code);
              return;
            }
          case 'events':
            if (request.method == 'GET') {
              await _pollEvents(request, code);
              return;
            }
          case 'signal':
            if (request.method == 'POST') {
              await _sendSignal(request, code);
              return;
            }
          case 'leave':
            if (request.method == 'POST') {
              await _leaveRoom(request, code);
              return;
            }
        }
      }
      _writeText(request.response, HttpStatus.notFound, 'not found');
    } catch (error) {
      if (!request.response.headersSent) {
        if (error is _RequestTooLarge) {
          _writeText(request.response, HttpStatus.requestEntityTooLarge, 'request body too large');
        } else if (error is FormatException) {
          _writeText(request.response, HttpStatus.badRequest, 'invalid request');
        } else {
          _writeText(request.response, HttpStatus.internalServerError, 'internal Core error');
        }
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _createRoom(HttpRequest request) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (!_allowAttempt(ip, _createRate, 6)) {
      _writeText(request.response, HttpStatus.tooManyRequests, 'too many room creation attempts; try again later');
      return;
    }
    await _readJson(request);
    _cleanupExpired();
    if (_rooms.length >= _maxActiveRooms) {
      _writeText(request.response, HttpStatus.serviceUnavailable, 'server has reached its active room limit');
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
    _writeJson(request.response, HttpStatus.created, <String, Object>{
      'code': code,
      'joinPin': pin,
      'expiresInSeconds': _roomTtl.inSeconds,
    });
  }

  Future<void> _joinRoom(HttpRequest request, String code) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (!_allowAttempt(ip, _joinRate, 12)) {
      _writeText(request.response, HttpStatus.tooManyRequests, 'too many invitation attempts; try again later');
      return;
    }
    final body = await _readJson(request);
    if (body['peerId'] is! String ||
        body['joinPin'] is! String ||
        (body['name'] != null && body['name'] is! String)) {
      _writeText(request.response, HttpStatus.badRequest, 'invalid peerId, name or invitation PIN');
      return;
    }
    final peerId = (body['peerId'] as String).trim();
    final rawName = (body['name'] as String? ?? '').trim();
    final pin = body['joinPin'] as String;
    if (peerId.length < 8 || peerId.length > 80 ||
        pin.length != 6 || !RegExp(r'^\d{6}
      _writeText(request.response, HttpStatus.badRequest, 'invalid peerId or invitation PIN');
      return;
    }
    final room = _rooms[code];
    if (room == null ||
        !DateTime.now().isBefore(room.expiresAt) ||
        !_constantTimeEquals(pin, room.joinPin)) {
      _writeText(request.response, HttpStatus.notFound, 'room not found or invitation PIN invalid');
      return;
    }
    if (room.peers.containsKey(peerId)) {
      _writeText(request.response, HttpStatus.conflict, 'peer already joined');
      return;
    }
    if (room.peers.length >= _maxRoomPeers) {
      _writeText(request.response, HttpStatus.conflict, 'room is full (maximum 3 devices)');
      return;
    }
    if (room.peers.values.any((peer) => peer.events.length >= _maxQueue)) {
      _writeText(request.response, HttpStatus.serviceUnavailable, 'room signaling queue is busy; retry shortly');
      return;
    }

    final existing = room.peers.values
        .map((peer) => <String, String>{'id': peer.id, 'name': peer.name})
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
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'peers': existing,
      'peerToken': peer.token,
      // ICE servers are supplied by an optional public signaling deployment.
      'iceServers': const <Object>[],
    });
  }

  Future<void> _pollEvents(HttpRequest request, String code) async {
    final peerId = request.uri.queryParameters['peerId']?.trim() ?? '';
    if (peerId.isEmpty) {
      _writeText(request.response, HttpStatus.badRequest, 'peerId required');
      return;
    }
    final room = _rooms[code];
    final peer = room?.peers[peerId];
    if (room == null || peer == null || !_authorized(request, peer)) {
      _writeText(request.response, HttpStatus.notFound, 'peer not joined or room expired');
      return;
    }
    if (peer.polling) {
      _writeText(request.response, HttpStatus.conflict, 'a long-poll request is already active');
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
          request.response.done,
        ]);
      }
      if (peer.done.isCompleted) {
        _writeText(request.response, HttpStatus.notFound, 'peer session expired');
        return;
      }
      peer.lastSeen = DateTime.now();
      final messages = <Map<String, Object?>>[];
      while (peer.events.isNotEmpty && messages.length < _maxQueue) {
        messages.add(peer.events.removeFirst());
      }
      _writeJson(request.response, HttpStatus.ok, messages);
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
      _writeText(request.response, HttpStatus.badRequest, 'valid sender, target and message type are required');
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
    if (from.length < 8 || from.length > 80 ||
        to.length < 8 || to.length > 80 || from == to ||
        !supported.contains(type)) {
      _writeText(request.response, HttpStatus.badRequest, 'valid sender, target and message type are required');
      return;
    }
    if (type == 'candidate-batch') {
      if (data is! Map || data['candidates'] is! List) {
        _writeText(request.response, HttpStatus.badRequest, 'invalid candidate batch');
        return;
      }
      final candidates = data['candidates'] as List;
      if (candidates.isEmpty || candidates.length > 8 ||
          candidates.any((item) => item is! Map ||
              item['candidate'] is! String ||
              (item['candidate'] as String).isEmpty ||
              (item['candidate'] as String).length > 2048)) {
        _writeText(request.response, HttpStatus.badRequest, 'candidate batch must contain 1 to 8 valid candidates');
        return;
      }
    }

    final room = _rooms[code];
    final sender = room?.peers[from];
    if (room == null || sender == null || !_authorized(request, sender)) {
      _writeText(request.response, HttpStatus.notFound, 'sender not joined or room expired');
      return;
    }
    final target = room.peers[to];
    if (target == null) {
      _writeText(request.response, HttpStatus.notFound, 'target peer not found');
      return;
    }
    if (!_enqueue(target, <String, Object?>{
      'type': type,
      'from': from,
      'to': to,
      if (data != null) 'data': data,
    })) {
      _writeText(request.response, HttpStatus.serviceUnavailable, 'target signaling queue is full; retry shortly');
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
      _writeText(request.response, HttpStatus.notFound, 'room or peer not found');
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
    final raw = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final supplied = raw.startsWith('Bearer ') ? raw.substring(7).trim() : '';
    return _constantTimeEquals(supplied, peer.token);
  }

  bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      difference |= x ^ y;
    }
    return difference == 0;
  }

  bool _allowAttempt(String ip, Map<String, _RateEntry> entries, int limit) {
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
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    return true;
  }

  void _removePeer(_Room room, String peerId) {
    final peer = room.peers.remove(peerId);
    if (peer == null) return;
    _finishPeer(peer);
    for (final other in room.peers.values) {
      if (!_enqueue(other, <String, Object?>{'type': 'peer-left', 'peerId': peerId})) {
        if (other.events.isNotEmpty) other.events.removeFirst();
        _enqueue(other, <String, Object?>{'type': 'peer-left', 'peerId': peerId});
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
      final stale = room.peers.values
          .where((peer) => now.difference(peer.lastSeen) > _peerIdleTtl)
          .map((peer) => peer.id)
          .toList(growable: false);
      for (final id in stale) {
        _removePeer(room, id);
      }
      // Keep newly-created empty rooms alive while their invitation is valid.
      if (hadPeers && room.peers.isEmpty) expiredRooms.add(entry.key);
    }
    for (final code in expiredRooms) {
      _rooms.remove(code);
    }
    _createRate.removeWhere((_, value) => !now.isBefore(value.resetAt));
    _joinRate.removeWhere((_, value) => !now.isBefore(value.resetAt));
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

  String _randomHex(int bytes) {
    const hex = '0123456789abcdef';
    return List<String>.generate(
      bytes * 2,
      (_) => hex[_random.nextInt(hex.length)],
      growable: false,
    ).join();
  }

  String _limitName(String value) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= 48) return value;
    return String.fromCharCodes(runes.take(48));
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    unawaited(response.close());
  }

  void _writeText(HttpResponse response, int status, String body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
    unawaited(response.close());
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
}).hasMatch(pin)) {
      _writeText(request.response, HttpStatus.badRequest, 'invalid peerId or invitation PIN');
      return;
    }
    final room = _rooms[code];
    if (room == null ||
        !DateTime.now().isBefore(room.expiresAt) ||
        !_constantTimeEquals(pin, room.joinPin)) {
      _writeText(request.response, HttpStatus.notFound, 'room not found or invitation PIN invalid');
      return;
    }
    if (room.peers.containsKey(peerId)) {
      _writeText(request.response, HttpStatus.conflict, 'peer already joined');
      return;
    }
    if (room.peers.length >= _maxRoomPeers) {
      _writeText(request.response, HttpStatus.conflict, 'room is full (maximum 3 devices)');
      return;
    }
    if (room.peers.values.any((peer) => peer.events.length >= _maxQueue)) {
      _writeText(request.response, HttpStatus.serviceUnavailable, 'room signaling queue is busy; retry shortly');
      return;
    }

    final existing = room.peers.values
        .map((peer) => <String, String>{'id': peer.id, 'name': peer.name})
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
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'peers': existing,
      'peerToken': peer.token,
      // ICE servers are supplied by an optional public signaling deployment.
      'iceServers': const <Object>[],
    });
  }

  Future<void> _pollEvents(HttpRequest request, String code) async {
    final peerId = request.uri.queryParameters['peerId']?.trim() ?? '';
    if (peerId.isEmpty) {
      _writeText(request.response, HttpStatus.badRequest, 'peerId required');
      return;
    }
    final room = _rooms[code];
    final peer = room?.peers[peerId];
    if (room == null || peer == null || !_authorized(request, peer)) {
      _writeText(request.response, HttpStatus.notFound, 'peer not joined or room expired');
      return;
    }
    if (peer.polling) {
      _writeText(request.response, HttpStatus.conflict, 'a long-poll request is already active');
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
          request.response.done,
        ]);
      }
      if (peer.done.isCompleted) {
        _writeText(request.response, HttpStatus.notFound, 'peer session expired');
        return;
      }
      peer.lastSeen = DateTime.now();
      final messages = <Map<String, Object?>>[];
      while (peer.events.isNotEmpty && messages.length < _maxQueue) {
        messages.add(peer.events.removeFirst());
      }
      _writeJson(request.response, HttpStatus.ok, messages);
    } finally {
      peer.waiter = null;
      peer.polling = false;
    }
  }

  Future<void> _sendSignal(HttpRequest request, String code) async {
    final body = await _readJson(request);
    final type = body['type'] as String? ?? '';
    final from = body['from'] as String? ?? '';
    final to = body['to'] as String? ?? '';
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
    if (from.length < 8 || from.length > 80 ||
        to.length < 8 || to.length > 80 || from == to ||
        !supported.contains(type)) {
      _writeText(request.response, HttpStatus.badRequest, 'valid sender, target and message type are required');
      return;
    }
    if (type == 'candidate-batch') {
      if (data is! Map || data['candidates'] is! List) {
        _writeText(request.response, HttpStatus.badRequest, 'invalid candidate batch');
        return;
      }
      final candidates = data['candidates'] as List;
      if (candidates.isEmpty || candidates.length > 8 ||
          candidates.any((item) => item is! Map ||
              item['candidate'] is! String ||
              (item['candidate'] as String).isEmpty ||
              (item['candidate'] as String).length > 2048)) {
        _writeText(request.response, HttpStatus.badRequest, 'candidate batch must contain 1 to 8 valid candidates');
        return;
      }
    }

    final room = _rooms[code];
    final sender = room?.peers[from];
    if (room == null || sender == null || !_authorized(request, sender)) {
      _writeText(request.response, HttpStatus.notFound, 'sender not joined or room expired');
      return;
    }
    final target = room.peers[to];
    if (target == null) {
      _writeText(request.response, HttpStatus.notFound, 'target peer not found');
      return;
    }
    if (!_enqueue(target, <String, Object?>{
      'type': type,
      'from': from,
      'to': to,
      if (data != null) 'data': data,
    })) {
      _writeText(request.response, HttpStatus.serviceUnavailable, 'target signaling queue is full; retry shortly');
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
      _writeText(request.response, HttpStatus.notFound, 'room or peer not found');
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
    final raw = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final supplied = raw.startsWith('Bearer ') ? raw.substring(7).trim() : '';
    return _constantTimeEquals(supplied, peer.token);
  }

  bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      difference |= x ^ y;
    }
    return difference == 0;
  }

  bool _allowAttempt(String ip, Map<String, _RateEntry> entries, int limit) {
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
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    return true;
  }

  void _removePeer(_Room room, String peerId) {
    final peer = room.peers.remove(peerId);
    if (peer == null) return;
    _finishPeer(peer);
    for (final other in room.peers.values) {
      if (!_enqueue(other, <String, Object?>{'type': 'peer-left', 'peerId': peerId})) {
        if (other.events.isNotEmpty) other.events.removeFirst();
        _enqueue(other, <String, Object?>{'type': 'peer-left', 'peerId': peerId});
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
      final stale = room.peers.values
          .where((peer) => now.difference(peer.lastSeen) > _peerIdleTtl)
          .map((peer) => peer.id)
          .toList(growable: false);
      for (final id in stale) {
        _removePeer(room, id);
      }
      if (room.peers.isEmpty) expiredRooms.add(entry.key);
    }
    for (final code in expiredRooms) {
      _rooms.remove(code);
    }
    _createRate.removeWhere((_, value) => !now.isBefore(value.resetAt));
    _joinRate.removeWhere((_, value) => !now.isBefore(value.resetAt));
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

  String _randomHex(int bytes) {
    const hex = '0123456789abcdef';
    return List<String>.generate(
      bytes * 2,
      (_) => hex[_random.nextInt(hex.length)],
      growable: false,
    ).join();
  }

  String _limitName(String value) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= 48) return value;
    return String.fromCharCodes(runes.take(48));
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    unawaited(response.close());
  }

  void _writeText(HttpResponse response, int status, String body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
    unawaited(response.close());
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