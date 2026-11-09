import 'dart:convert';
import 'dart:typed_data';

class FileTransferChunk {
  const FileTransferChunk({
    required this.transferId,
    required this.index,
    required this.payload,
  });

  final String transferId;
  final int index;
  final Uint8List payload;
}

class FileTransferProtocol {
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int chunkBytes = 16 * 1024;
  static const int headerBytes = 40;
  static const List<int> _magic = [0x4D, 0x54, 0x46, 0x31]; // MTF1

  static bool isValidTransferId(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

  static Uint8List encodeChunk({
    required String transferId,
    required int index,
    required Uint8List payload,
  }) {
    if (!isValidTransferId(transferId)) {
      throw const FormatException('Invalid MTUNZ transfer identifier.');
    }
    if (index < 0 || index > 0xFFFFFFFF) {
      throw RangeError.range(index, 0, 0xFFFFFFFF, 'index');
    }
    if (payload.isEmpty || payload.length > chunkBytes) {
      throw RangeError.range(payload.length, 1, chunkBytes, 'payload length');
    }

    final frame = Uint8List(headerBytes + payload.length);
    frame.setRange(0, 4, _magic);
    frame.setRange(4, 36, ascii.encode(transferId));
    ByteData.sublistView(frame).setUint32(36, index, Endian.big);
    frame.setRange(headerBytes, frame.length, payload);
    return frame;
  }

  static FileTransferChunk? decodeChunk(Uint8List frame) {
    if (frame.length <= headerBytes || frame.length > headerBytes + chunkBytes) {
      return null;
    }
    for (var i = 0; i < _magic.length; i++) {
      if (frame[i] != _magic[i]) return null;
    }

    late final String transferId;
    try {
      transferId = ascii.decode(frame.sublist(4, 36), allowInvalid: false);
    } on FormatException {
      return null;
    }
    if (!isValidTransferId(transferId)) return null;
    final index = ByteData.sublistView(frame).getUint32(36, Endian.big);
    return FileTransferChunk(
      transferId: transferId,
      index: index,
      payload: Uint8List.sublistView(frame, headerBytes),
    );
  }

  static String sanitizeFileName(String input) {
    final leafName = input.replaceAll('\\', '/').split('/').last;
    final cleaned = leafName
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'received-file';
    final runes = cleaned.runes.toList(growable: false);
    return runes.length <= 180 ? cleaned : String.fromCharCodes(runes.take(180));
  }
}
