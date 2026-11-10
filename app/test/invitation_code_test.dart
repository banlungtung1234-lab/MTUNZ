import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/invitation_code.dart';

void main() {
  test('encodes and decodes a single LAN invitation code', () {
    final code = InvitationCode.encode(serverUrl: 'http://192.168.1.20:8787/', roomCode: 'ABCDEFGH', pin: '123456');
    expect(code, startsWith('MTZ1-'));
    final decoded = InvitationCode.decode(code);
    expect(decoded.serverUrl, 'http://192.168.1.20:8787');
    expect(decoded.roomCode, 'ABCDEFGH');
    expect(decoded.pin, '123456');
  });

  test('supports a public HTTPS signaling URL and path prefix', () {
    final code = InvitationCode.encode(serverUrl: 'https://signal.example.net/mtunz/', roomCode: 'JKLMNPQR', pin: '987654');
    final decoded = InvitationCode.decode(code);
    expect(decoded.serverUrl, 'https://signal.example.net/mtunz');
    expect(decoded.roomCode, 'JKLMNPQR');
  });

  test('ignores whitespace pasted inside a token', () {
    final code = InvitationCode.encode(serverUrl: 'http://10.0.0.2:8787', roomCode: 'ABCDEFGH', pin: '123456');
    final spaced = '${code.substring(0, 12)} ${String.fromCharCode(10)} ${code.substring(12)}';
    expect(InvitationCode.decode(spaced).roomCode, 'ABCDEFGH');
  });

  test('rejects malformed codes and public HTTP signaling', () {
    expect(() => InvitationCode.decode('ABCDEFGH'), throwsA(isA<FormatException>()));
    expect(() => InvitationCode.decode('MTZ1-not-base64!'), throwsA(isA<FormatException>()));
    expect(() => InvitationCode.encode(serverUrl: 'http://signal.example.net', roomCode: 'ABCDEFGH', pin: '123456'),
      throwsA(isA<FormatException>()));
  });

  test('rejects invalid credentials and oversized invitation tokens', () {
    expect(() => InvitationCode.encode(serverUrl: 'https://signal.example.net', roomCode: 'badcode!', pin: '123456'),
      throwsA(isA<FormatException>()));
    final oversized = List<String>.filled(InvitationCode.maxLength + 1, 'A').join();
    expect(() => InvitationCode.decode('MTZ1-$oversized'), throwsA(isA<FormatException>()));
  });
}
