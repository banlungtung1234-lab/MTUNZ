import 'dart:convert';
import 'dart:io';

class InvitationPayload {
  const InvitationPayload({required this.serverUrl, required this.roomCode, required this.pin});
  final String serverUrl;
  final String roomCode;
  final String pin;
}

/// A copy/paste envelope, not encryption. Anyone holding it can attempt to
/// join the room until its normal expiry.
class InvitationCode {
  static const String prefix = 'MTZ1-';
  static const int maxLength = 512;
  static final RegExp _roomCodePattern = RegExp(r'^[A-HJ-NP-Z2-9]{8}$');
  static final RegExp _pinPattern = RegExp(r'^\d{6}$');

  static String encode({required String serverUrl, required String roomCode, required String pin}) {
    final normalizedCode = roomCode.trim().toUpperCase();
    final normalizedPin = pin.trim();
    if (!_roomCodePattern.hasMatch(normalizedCode) || !_pinPattern.hasMatch(normalizedPin)) {
      throw const FormatException('Thông tin phòng không hợp lệ; hãy tạo lại lời mời.');
    }
    final base = _validateServerUrl(serverUrl);
    final payload = jsonEncode({'v': 1, 'u': base.toString(), 'c': normalizedCode, 'p': normalizedPin});
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    final token = '$prefix$encoded';
    if (token.length > maxLength) throw const FormatException('Địa chỉ máy chủ quá dài để tạo mã mời.');
    return token;
  }

  static InvitationPayload decode(String raw) {
    final token = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (token.length > maxLength || !token.startsWith(prefix)) {
      throw const FormatException('Mã mời MTUNZ không hợp lệ. Hãy dán toàn bộ mã bắt đầu bằng MTZ1-.');
    }
    final encoded = token.substring(prefix.length);
    if (encoded.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const FormatException('Mã mời MTUNZ bị thiếu hoặc sai định dạng.');
    }
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) {
        throw const FormatException('Phiên bản mã mời MTUNZ không được hỗ trợ.');
      }
      final serverUrl = decoded['u'];
      final roomCode = decoded['c'];
      final pin = decoded['p'];
      if (serverUrl is! String || roomCode is! String || pin is! String ||
          !_roomCodePattern.hasMatch(roomCode) || !_pinPattern.hasMatch(pin)) {
        throw const FormatException('Mã mời không chứa đủ thông tin kết nối hợp lệ.');
      }
      return InvitationPayload(
        serverUrl: _validateServerUrl(serverUrl).toString(),
        roomCode: roomCode,
        pin: pin,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Không thể đọc mã mời MTUNZ. Hãy sao chép lại toàn bộ mã.');
    }
  }

  static Uri _validateServerUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('URL máy chủ trong mã mời không hợp lệ.');
    }
    if (uri.scheme == 'http' && !_isLocalNetworkHost(uri.host)) {
      throw const FormatException('Máy chủ Internet phải dùng HTTPS. HTTP chỉ được chấp nhận cho địa chỉ LAN/VPN riêng.');
    }
    final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    return uri.replace(path: path);
  }

  static bool isLocalNetworkHost(String host) => _isLocalNetworkHost(host);

  static bool _isLocalNetworkHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost') || normalized.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false;
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
    }
    return bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc;
  }
}
