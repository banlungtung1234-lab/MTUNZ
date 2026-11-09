import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/embedded_signaling_server.dart';
import 'package:mtunz/services/signaling_client.dart';

void main() {
  late EmbeddedSignalingServer core;
  late SignalingClient host;
  late SignalingClient guest;

  setUp(() async {
    core = EmbeddedSignalingServer();
    await core.start(preferredPort: 0);
    final url = core.localUri.toString();
    host = SignalingClient(serverUrl: url, deviceName: 'MTUNZ Host');
    guest = SignalingClient(serverUrl: url, deviceName: 'MTUNZ Guest');
  });

  tearDown(() async {
    await guest.leave();
    await host.leave();
    await core.close();
  });

  test('Health probe validates the embedded Core before pairing', () async {
    final health = await SignalingClient.checkHealth(core.localUri.toString());
    expect(health['ok'], isTrue);
    expect(health['service'], 'mtunz-embedded-core');
  });

  test('SignalingClient can create, host, join and exchange peer signals', () async {
    final invite = await host.createRoom();
    expect(invite.code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{8}$')));
    expect(invite.pin, matches(RegExp(r'^\d{6}$')));

    final hostInfo = await host.joinRoom(invite.code, invite.pin);
    expect(hostInfo.peers, isEmpty);
    expect(hostInfo.peerToken, hasLength(64));

    final joinedEvent = host.events.firstWhere(
      (event) => event['type'] == 'peer-joined',
    ).timeout(const Duration(seconds: 3));

    final guestInfo = await guest.joinRoom(invite.code, invite.pin);
    expect(guestInfo.peers, hasLength(1));
    expect(guestInfo.peers.single['id'], host.peerId);

    final peerJoined = await joinedEvent;
    expect((peerJoined['peer'] as Map)['id'], guest.peerId);

    final offerEvent = guest.events.firstWhere(
      (event) => event['type'] == 'offer',
    ).timeout(const Duration(seconds: 3));

    await host.sendSignal(
      guest.peerId,
      'offer',
      const {'type': 'offer', 'sdp': 'test-sdp'},
    );

    final offer = await offerEvent;
    expect(offer['from'], host.peerId);
    expect(offer['to'], guest.peerId);
    expect((offer['data'] as Map)['sdp'], 'test-sdp');

    final leftEvent = host.events.firstWhere(
      (event) => event['type'] == 'peer-left',
    ).timeout(const Duration(seconds: 3));

    await guest.leave();
    final left = await leftEvent;
    expect(left['peerId'], guest.peerId);
  });

  test('The joining client must use the host address, not its own loopback', () async {
    final invite = await host.createRoom();
    await host.joinRoom(invite.code, invite.pin);

    final wrongCore = EmbeddedSignalingServer();
    await wrongCore.start(preferredPort: 0);
    final wrongClient = SignalingClient(
      serverUrl: wrongCore.localUri.toString(),
      deviceName: 'Wrong host',
    );
    try {
      await expectLater(
        wrongClient.joinRoom(invite.code, invite.pin),
        throwsA(isA<SignalingHttpException>().having(
          (error) => error.statusCode,
          'statusCode',
          404,
        )),
      );
    } finally {
      await wrongClient.leave();
      await wrongCore.close();
    }
  });
}
