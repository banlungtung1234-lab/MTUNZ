import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/rtc_mesh.dart';
import 'package:mtunz/services/signaling_client.dart';

void main() {
  test('RTC mesh accepts temporary TURN ICE server configuration', () async {
    final signaling = SignalingClient(
      serverUrl: 'http://127.0.0.1:8787',
      deviceName: 'MTUNZ test',
    );
    const iceServers = <Map<String, dynamic>>[
      {
        'urls': ['turn:turn.example.net:3478?transport=udp'],
        'username': '1790000000:peer-test',
        'credential': 'short-lived-credential',
      },
    ];
    final mesh = RtcMesh(
      signaling: signaling,
      iceServers: iceServers,
      onChanged: (_) {},
      onControlRequest: (_, __) async {},
      onNotice: (_) {},
      onSharingChanged: (_) {},
      onFileOffer: (_, __, ___, ____) async => false,
      onFileReceived: (_, __, ___) async => false,
      onFileTransfersChanged: (_) {},
    );

    try {
      expect(mesh.iceServers, equals(iceServers));
    } finally {
      await mesh.dispose();
      await signaling.leave();
    }
  });
}
