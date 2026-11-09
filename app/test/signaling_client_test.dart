import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/signaling_client.dart';

void main() {
  test('join response keeps valid STUN/TURN servers and temporary credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peerToken = List<String>.filled(64, 'a').join();
    const turnUrl = 'turn:turn.example.net:3478?transport=udp';
    const username = '1790000000:peer-test';
    const credential = 'short-lived-credential';

    server.listen((request) async {
      if (request.uri.path.endsWith('/join')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'peerToken': peerToken,
          'peers': const [],
          'iceServers': [
            {
              'urls': [turnUrl, 'https://not-an-ice-server.example'],
              'username': username,
              'credential': credential,
            },
            {'urls': 'stun:stun.example.net:3478'},
            {'urls': 'https://invalid.example'},
          ],
        }));
        await request.response.close();
      } else if (request.uri.path.endsWith('/events')) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        request.response.write('[]');
        await request.response.close();
      } else if (request.uri.path.endsWith('/leave')) {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });

    final client = SignalingClient(
      serverUrl: 'http://127.0.0.1:${server.port}',
      deviceName: 'MTUNZ test',
    );
    try {
      final joined = await client.joinRoom('ABCDEFGH', '123456');
      expect(joined.iceServers, [
        {
          'urls': [turnUrl],
          'username': username,
          'credential': credential,
        },
        {
          'urls': ['stun:stun.example.net:3478'],
        },
      ]);
    } finally {
      await client.leave();
      await server.close(force: true);
    }
  });
}
