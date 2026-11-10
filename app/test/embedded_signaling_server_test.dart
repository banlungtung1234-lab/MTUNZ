import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/embedded_signaling_server.dart';

void main() {
  late EmbeddedSignalingServer core;
  late HttpClient http;

  setUp(() async {
    core = EmbeddedSignalingServer();
    await core.start();
    http = HttpClient()..findProxy = (_) => 'DIRECT';
  });

  tearDown(() async {
    http.close(force: true);
    await core.close();
  });

  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    final parsedPath = Uri.parse(path);
    final requestUri = core.localUri.replace(
      path: parsedPath.path,
      query: parsedPath.hasQuery ? parsedPath.query : null,
    );
    final request = await http.openUrl(method, requestUri);
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final responseText = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: $responseText');
    }
    if (responseText.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(responseText);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'items': decoded};
  }

  test('embedded Core starts on a free port and exposes health check', () async {
    expect(core.isRunning, isTrue);
    expect(core.port, greaterThan(0));
    final response = await requestJson('GET', '/healthz');
    expect(response['ok'], isTrue);
    expect(response['service'], 'mtunz-embedded-core');
  });

  test('two clients exchange peer-joined, SDP signal and peer-left events', () async {
    final invite = await requestJson('POST', '/api/rooms', body: const {});
    final code = invite['code'] as String;
    final pin = invite['joinPin'] as String;
    expect(code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{8}$')));
    expect(pin, matches(RegExp(r'^\d{6}$')));
    const firstId = '0123456789abcdef01234567';
    const secondId = '89abcdef0123456701234567';

    final first = await requestJson(
      'POST',
      '/api/rooms/$code/join',
      body: {'peerId': firstId, 'name': 'Windows', 'joinPin': pin},
    );
    final firstToken = first['peerToken'] as String;

    final second = await requestJson(
      'POST',
      '/api/rooms/$code/join',
      body: {'peerId': secondId, 'name': 'Android', 'joinPin': pin},
    );
    final secondToken = second['peerToken'] as String;

    final joinedEvents = await requestJson(
      'GET',
      '/api/rooms/$code/events?peerId=$firstId',
      token: firstToken,
    );
    expect(joinedEvents['items'], isA<List>());
    expect((joinedEvents['items'] as List).single['type'], 'peer-joined');

    await requestJson(
      'POST',
      '/api/rooms/$code/signal',
      token: firstToken,
      body: const {
        'type': 'offer',
        'from': firstId,
        'to': secondId,
        'data': {'sdp': 'test-sdp', 'type': 'offer'},
      },
    );

    final signalEvents = await requestJson(
      'GET',
      '/api/rooms/$code/events?peerId=$secondId',
      token: secondToken,
    );
    final signal = (signalEvents['items'] as List).single as Map;
    expect(signal['type'], 'offer');
    expect(signal['from'], firstId);
    expect((signal['data'] as Map)['sdp'], 'test-sdp');

    final leave = await http.postUrl(core.localUri.replace(
      path: '/api/rooms/$code/leave',
      queryParameters: {'peerId': secondId},
    ));
    leave.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secondToken');
    leave.headers.contentType = ContentType.json;
    leave.write('{}');
    final leaveResponse = await leave.close();
    expect(leaveResponse.statusCode, HttpStatus.noContent);
    await leaveResponse.drain<void>();

    final leftEvents = await requestJson(
      'GET',
      '/api/rooms/$code/events?peerId=$firstId',
      token: firstToken,
    );
    expect((leftEvents['items'] as List).single['type'], 'peer-left');
    expect((leftEvents['items'] as List).single['peerId'], secondId);
  });

  test('unauthenticated signal and malformed candidate batch are rejected', () async {
    final invite = await requestJson('POST', '/api/rooms', body: const {});
    final code = invite['code'] as String;
    final pin = invite['joinPin'] as String;
    const firstId = '0123456789abcdef01234567';
    const secondId = '89abcdef0123456701234567';
    final first = await requestJson(
      'POST',
      '/api/rooms/$code/join',
      body: {'peerId': firstId, 'name': 'Windows', 'joinPin': pin},
    );
    await requestJson(
      'POST',
      '/api/rooms/$code/join',
      body: {'peerId': secondId, 'name': 'Android', 'joinPin': pin},
    );
    final firstToken = first['peerToken'] as String;

    final unauthenticated = await http.postUrl(core.localUri.replace(path: '/api/rooms/$code/signal'));
    unauthenticated.headers.contentType = ContentType.json;
    unauthenticated.write(jsonEncode({
      'type': 'offer',
      'from': firstId,
      'to': secondId,
      'data': const {},
    }));
    final denied = await unauthenticated.close();
    expect(denied.statusCode, HttpStatus.notFound);
    await denied.drain<void>();

    final malformed = await http.postUrl(core.localUri.replace(path: '/api/rooms/$code/signal'));
    malformed.headers.contentType = ContentType.json;
    malformed.headers.set(HttpHeaders.authorizationHeader, 'Bearer $firstToken');
    malformed.write(jsonEncode({
      'type': 'candidate-batch',
      'from': firstId,
      'to': secondId,
      'data': {'candidates': List.generate(9, (_) => {'candidate': 'candidate:1'})},
    }));
    final badBatch = await malformed.close();
    expect(badBatch.statusCode, HttpStatus.badRequest);
    await badBatch.drain<void>();
  });
}
