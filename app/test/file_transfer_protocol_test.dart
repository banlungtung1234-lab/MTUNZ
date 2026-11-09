import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/file_transfer_protocol.dart';

void main() {
  test('encodes and decodes an ordered binary chunk', () {
    final payload = Uint8List.fromList([0, 1, 2, 127, 255]);
    final frame = FileTransferProtocol.encodeChunk(
      transferId: '0123456789abcdef0123456789abcdef',
      index: 42,
      payload: payload,
    );

    final decoded = FileTransferProtocol.decodeChunk(frame);
    expect(decoded, isNotNull);
    expect(decoded!.transferId, '0123456789abcdef0123456789abcdef');
    expect(decoded.index, 42);
    expect(decoded.payload, payload);
  });

  test('rejects malformed frames and invalid chunk sizes', () {
    expect(FileTransferProtocol.decodeChunk(Uint8List(80)), isNull);
    expect(
      () => FileTransferProtocol.encodeChunk(
        transferId: 'bad-id',
        index: 0,
        payload: Uint8List.fromList([1]),
      ),
      throwsFormatException,
    );
    expect(
      () => FileTransferProtocol.encodeChunk(
        transferId: '0123456789abcdef0123456789abcdef',
        index: 0,
        payload: Uint8List(FileTransferProtocol.chunkBytes + 1),
      ),
      throwsRangeError,
    );
  });

  test('rejects frames with invalid transfer id bytes or magic', () {
    final invalidId = Uint8List(41);
    invalidId.setRange(0, 4, [0x4D, 0x54, 0x46, 0x31]);
    for (var index = 4; index < 36; index++) {
      invalidId[index] = 0xFF;
    }
    expect(FileTransferProtocol.decodeChunk(invalidId), isNull);

    final invalidMagic = FileTransferProtocol.encodeChunk(
      transferId: '0123456789abcdef0123456789abcdef',
      index: 0,
      payload: Uint8List.fromList([7]),
    );
    invalidMagic[0] = 0;
    expect(FileTransferProtocol.decodeChunk(invalidMagic), isNull);
  });

  test('sanitizes paths and unsafe file-name characters', () {
    expect(FileTransferProtocol.sanitizeFileName(r'C:\\private\\report?.pdf'), 'report_.pdf');
    expect(FileTransferProtocol.sanitizeFileName('../'), 'received-file');
    expect(FileTransferProtocol.sanitizeFileName('CON.txt'), '_CON.txt');
    expect(FileTransferProtocol.sanitizeFileName('LPT1'), '_LPT1');
  });
}
