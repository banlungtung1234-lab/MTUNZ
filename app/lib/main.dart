import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_strings.dart';

import 'services/platform_controller.dart';
import 'services/embedded_signaling_server.dart';
import 'services/invitation_code.dart';
import 'services/file_transfer_protocol.dart';
import 'services/rtc_mesh.dart';
import 'services/signaling_client.dart';
import 'services/network_interfaces.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MtunzApp());
}

class MtunzApp extends StatefulWidget {
  const MtunzApp({super.key});

  @override
  State<MtunzApp> createState() => _MtunzAppState();
}

class _MtunzAppState extends State<MtunzApp> {
  static const _localePreferenceKey = 'mtunz.locale';
  Locale _locale = const Locale('vi');

  @override
  void initState() {
    super.initState();
    _restoreLocale();
  }

  Future<void> _restoreLocale() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedCode = preferences.getString(_localePreferenceKey);
      if (savedCode != null && AppStrings.languages.containsKey(savedCode) && mounted) {
        setState(() => _locale = Locale(savedCode));
      }
    } catch (_) {
      // Keep Vietnamese as a safe default if preferences are unavailable.
    }
  }

  Future<void> _setLocale(Locale locale) async {
    final code = locale.languageCode;
    if (!AppStrings.languages.containsKey(code)) return;
    setState(() => _locale = locale);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_localePreferenceKey, code);
    } catch (_) {
      // The language still changes for this run if persistence is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF080D18);
    const panel = Color(0xFF111A2B);
    const accent = Color(0xFF38D8F2);
    return MaterialApp(
      title: 'MTUNZ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: Color(0xFF9B8CFF),
          surface: panel,
          error: Color(0xFFFF6B7A),
        ),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
        cardTheme: CardThemeData(
          color: panel,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0C1423),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF26354D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF26354D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: accent, width: 1.4),
          ),
        ),
      ),
      locale: _locale,
      home: HomeShell(locale: _locale, onLocaleChanged: _setLocale),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.locale, required this.onLocaleChanged});

  final Locale locale;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _serverController = TextEditingController();
  final EmbeddedSignalingServer _embeddedCore = EmbeddedSignalingServer();
  final _codeController = TextEditingController();
  int _selectedIndex = 0;
  String _serverUrl = '';
  bool _coreStarting = false;
  Future<void>? _coreStartup;
  bool _usesEmbeddedCore = true;
  String? _coreError;
  String _statusKey = 'status_not_connected';
  int _connectedPeerCount = 0;
  String get _statusText => _statusKey == 'status_connected_count'
      ? _t('status_connected_count', {'count': '$_connectedPeerCount'})
      : _t(_statusKey);
  String? _roomCode;
  String? _roomPin;
  bool _sharing = false;
  bool _busy = false;
  String _notice = 'notice_ready';
  bool _noticeIsKey = true;
  SignalingClient? _signaling;
  RtcMesh? _mesh;
  List<PeerView> _peers = const [];
  List<FileTransferView> _fileTransfers = const [];
  String? _selectedFilePeerId;
  bool _filePickerBusy = false;
  bool _networkScanBusy = false;
  Future<void>? _networkScanTask;
  List<NetworkEndpoint> _networkEndpoints = const [];

  String _t(String key, [Map<String, String> values = const {}]) =>
      AppStrings.text(widget.locale.languageCode, key, values);

  @override
  void initState() {
    super.initState();
    unawaited(_startEmbeddedCore());
  }

  Future<void> _startEmbeddedCore() {
    // Await the in-flight startup even after the socket has been bound: the
    // startup task also discovers LAN addresses for the invitation UI.
    final runningTask = _coreStartup;
    if (runningTask != null) return runningTask;
    if (_embeddedCore.isRunning) return Future<void>.value();

    late final Future<void> startup;
    startup = _startEmbeddedCoreInternal().whenComplete(() {
      if (identical(_coreStartup, startup)) _coreStartup = null;
    });
    _coreStartup = startup;
    return startup;
  }

  Future<void> _startEmbeddedCoreInternal() async {
    if (_embeddedCore.isRunning) return;
    if (mounted) setState(() => _coreStarting = true);
    try {
      // Port 8787 is preferred for predictable LAN sharing. If another app
      // already owns it, the embedded Core safely uses an available port.
      await _embeddedCore.start(preferredPort: 8787);
      if (!mounted) return;
      final localUrl = _embeddedCore.localUri.toString();
      setState(() {
        if (_serverUrl.isEmpty || _usesEmbeddedCore) {
          _serverUrl = localUrl;
          _serverController.text = localUrl;
          _usesEmbeddedCore = true;
        }
        _coreError = null;
        _coreStarting = false;
      });
      await _scanNetworkInterfaces();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _coreError = '$error';
        _coreStarting = false;
      });
    } finally {
      if (mounted && _coreStarting) {
        setState(() => _coreStarting = false);
      }
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    unawaited(_disconnect().catchError((_) {}));
    unawaited(_embeddedCore.close());
    super.dispose();
  }

  Future<void> _createRoom() async {
    // Embedded Core remains the LAN/VPN default. A custom HTTPS signaling
    // service configured in Settings is used for cross-Internet rooms.
    if (_usesEmbeddedCore) {
      if (!_embeddedCore.isRunning) await _startEmbeddedCore();
      if (!_embeddedCore.isRunning) {
        _showSnack('Không thể khởi động MTUNZ Core: ${_coreError ?? 'không rõ nguyên nhân'}');
        return;
      }
      final localUrl = _embeddedCore.localUri.toString();
      if (mounted) {
        setState(() {
          _serverUrl = localUrl;
          _serverController.text = localUrl;
          _usesEmbeddedCore = true;
        });
      }
    } else if (!_ensureServerConfigured()) {
      return;
    }
    final hostServerUrl = _serverUrl;
    final hostingOnEmbeddedCore = _usesEmbeddedCore;
    await _withBusy(() async {
      await SignalingClient.checkHealth(hostServerUrl);
      await _disconnect();
      final client = _newClient(serverUrl: hostServerUrl);
      var attached = false;
      try {
        final invite = await client.createRoom();
        final joined = await client.joinRoom(invite.code, invite.pin);
        if (!mounted) {
          await client.leave();
          return;
        }
        _attach(client, joined);
        attached = true;
        setState(() {
          _roomCode = invite.code;
          // Keep the host marker, but never show the PIN separately.
          _roomPin = invite.pin;
          _statusKey = 'status_waiting';
          _notice = 'notice_room_ready';
          _noticeIsKey = true;
        });
        if (hostingOnEmbeddedCore) await _scanNetworkInterfaces();
        _showInvite(invite, serverUrl: hostServerUrl, embeddedCore: hostingOnEmbeddedCore);
      } catch (_) {
        if (!attached) await client.leave();
        rethrow;
      }
    });
  }

  Future<void> _joinRoom(InvitationPayload invitation) async {
    final target = Uri.tryParse(invitation.serverUrl);
    if (target != null && _isThisDeviceAddress(target.host)) {
      _showSnack('Mã mời trỏ về chính thiết bị này. Hãy dùng mã được tạo trên thiết bị chủ và chọn đúng mạng.');
      return;
    }
    await _withBusy(() async {
      await SignalingClient.checkHealth(invitation.serverUrl);
      await _disconnect();
      final client = _newClient(serverUrl: invitation.serverUrl);
      var attached = false;
      try {
        final joined = await client.joinRoom(invitation.roomCode, invitation.pin);
        if (!mounted) {
          await client.leave();
          return;
        }
        _attach(client, joined);
        attached = true;
        setState(() {
          _roomCode = invitation.roomCode;
          _roomPin = null;
          _statusKey = 'status_joined';
          _notice = 'notice_signaling_connected';
          _noticeIsKey = true;
          _selectedIndex = 2;
        });
        _showSnack(_t('join_success', {'code': invitation.roomCode}));
      } catch (_) {
        if (!attached) await client.leave();
        rethrow;
      }
    });
  }

  SignalingClient _newClient({String? serverUrl}) => SignalingClient(
        serverUrl: serverUrl ?? _serverUrl,
        deviceName: Platform.isAndroid ? 'MTUNZ Android' : 'MTUNZ Windows',
      );

  void _attach(SignalingClient client, JoinInfo joined) {
    _signaling = client;
    _mesh = RtcMesh(
      signaling: client,
      iceServers: joined.iceServers,
      onChanged: (peers) {
        if (!mounted) return;
        setState(() {
          _peers = peers;
          if (_selectedFilePeerId == null || !peers.any((peer) => peer.id == _selectedFilePeerId)) {
            _selectedFilePeerId = peers.isEmpty ? null : peers.first.id;
          }
          _statusKey = peers.isEmpty ? 'status_waiting' : 'status_connected_count';
          _connectedPeerCount = peers.length;
        });
      },
      onControlRequest: _handleControlRequest,
      onSharingChanged: (sharing) {
        if (!mounted) return;
        setState(() => _sharing = sharing);
      },
      onNotice: (message) {
        if (!mounted) return;
        setState(() {
          _notice = message;
          _noticeIsKey = false;
        });
      },
      onFileOffer: _handleFileOffer,
      onFileReceived: _saveReceivedFile,
      onFileTransfersChanged: (transfers) {
        if (!mounted) return;
        setState(() => _fileTransfers = transfers);
      },
    );
    unawaited(_mesh!.handleExistingPeers(joined.peers));
  }

  Future<void> _handleControlRequest(String peerId, String peerName) async {
    if (!mounted) return;
    if (!Platform.isAndroid && !Platform.isWindows) {
      _showSnack(_t('unsupported_platform'));
      return;
    }
    if (Platform.isAndroid) {
      final accessibilityEnabled = await PlatformController.isAccessibilityEnabled();
      if (!mounted) return;
      if (!accessibilityEnabled) {
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_t('accessibility_required')),
            content: Text(_t('accessibility_explain')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t('later'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(_t('open_settings'))),
            ],
          ),
        );
        if (openSettings == true) await PlatformController.openAccessibilitySettings();
        return;
      }
    }
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('control_request_title')),
        content: Text(_t('control_request_body', {'name': peerName})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t('deny'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(_t('allow'))),
        ],
      ),
    );
    await _mesh?.setRemoteControlPermission(peerId, allow == true);
  }

  Future<bool> _handleFileOffer(String peerId, String peerName, String fileName, int size) async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.file_download_outlined, color: Color(0xFF55DFF4), size: 34),
        title: Text(_t('files_offer_title')),
        content: SizedBox(
          width: 390,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_t('files_offer_body', {
                'device': peerName,
                'name': fileName,
                'size': _formatBytes(size),
              })),
              const SizedBox(height: 12),
              Text(_t('files_offer_note'), style: const TextStyle(color: Color(0xFF90A2BA), fontSize: 11)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_t('files_decline'))),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.download_rounded, size: 17),
            label: Text(_t('files_accept')),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<bool> _saveReceivedFile(String peerName, String fileName, Uint8List bytes) async {
    if (!mounted) return false;
    final saved = await FilePicker.saveFile(
      dialogTitle: _t('files_save_title'),
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/octet-stream',
    );
    if (saved == null) {
      _showSnack(_t('files_save_cancelled'));
      return false;
    }
    _showSnack(_t('files_saved', {'name': fileName}));
    return true;
  }

  Future<void> _startFileTransfer() async {
    final mesh = _mesh;
    final peerId = _selectedFilePeerId;
    if (mesh == null || peerId == null) {
      _showSnack(_t('files_need_connection'));
      return;
    }
    if (_filePickerBusy) return;
    setState(() => _filePickerBusy = true);
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;
      final size = picked.lengthSync() ?? await picked.length();
      if (size == null) throw StateError(_t('files_cannot_read'));
      if (size > FileTransferProtocol.maxFileBytes) {
        throw StateError(_t('files_too_large'));
      }
      await mesh.sendFile(
        peerId: peerId,
        fileName: picked.name,
        size: size,
        content: picked.readAsByteStream(),
      );
    } catch (error) {
      _showSnack(_t('operation_failed', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _filePickerBusy = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fileStatusLabel(String status) {
    switch (status) {
      case 'waiting': return _t('files_status_waiting');
      case 'sending': return _t('files_status_sending');
      case 'receiving': return _t('files_status_receiving');
      case 'saving': return _t('files_status_saving');
      case 'sent': return _t('files_status_sent');
      case 'completed': return _t('files_status_completed');
      case 'rejected': return _t('files_status_rejected');
      case 'cancelled': return _t('files_status_cancelled');
      case 'not_saved': return _t('files_status_not_saved');
      default: return _t('files_status_failed');
    }
  }

  Future<void> _startShare() async {
    await _withBusy(() async {
      final mesh = _mesh;
      if (mesh == null) throw StateError(_t('share_first'));
      await mesh.startScreenShare();
      if (mounted) setState(() => _sharing = true);
    });
  }

  Future<void> _stopShare() async {
    await _withBusy(() async {
      await _mesh?.stopScreenShare();
      if (mounted) setState(() => _sharing = false);
    });
  }

  Future<void> _disconnect() async {
    // Detach references first so a second cleanup cannot act on the same
    // native resources while this cleanup is awaiting platform channels.
    final mesh = _mesh;
    final signaling = _signaling;
    _mesh = null;
    _signaling = null;
    Object? firstError;
    try {
      await mesh?.dispose();
    } catch (error) {
      firstError ??= error;
    }
    try {
      await signaling?.leave();
    } catch (error) {
      firstError ??= error;
    }
    if (mounted) {
      setState(() {
        _peers = const [];
        _roomCode = null;
        _roomPin = null;
        _sharing = false;
        _statusKey = 'status_not_connected';
        _connectedPeerCount = 0;
        _fileTransfers = const [];
        _selectedFilePeerId = null;
      });
    }
    if (firstError != null) {
      throw StateError(_t('operation_failed', {'error': '$firstError'}));
    }
  }

  Future<void> _withBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showSnack(_t('operation_failed', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showInvite(
    RoomInvite invite, {
    required String serverUrl,
    required bool embeddedCore,
  }) {
    final targets = <Map<String, String>>[];
    if (embeddedCore) {
      for (final endpoint in _networkEndpoints.take(8)) {
        final url = 'http://${endpoint.address}:${_embeddedCore.port}';
        targets.add({
          'label': '${_networkKindLabel(endpoint.kind)} · ${endpoint.interfaceName}',
          'code': InvitationCode.encode(serverUrl: url, roomCode: invite.code, pin: invite.pin),
        });
      }
    } else {
      targets.add({
        'label': 'Máy chủ signaling đã cấu hình',
        'code': InvitationCode.encode(serverUrl: serverUrl, roomCode: invite.code, pin: invite.pin),
      });
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('room_created')),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chỉ cần gửi MỘT mã bên dưới cho thiết bị còn lại. Mã đã chứa địa chỉ kết nối và thông tin xác thực; bên nhận không cần nhập URL hoặc PIN riêng.',
                  style: TextStyle(color: Color(0xFFB7C8DC), fontSize: 11, height: 1.45),
                ),
                const SizedBox(height: 12),
                Text(
                  _t('room_expires', {'minutes': '${invite.expiresInSeconds ~/ 60}'}),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
                ),
                const SizedBox(height: 14),
                if (targets.isEmpty)
                  const Text(
                    'Không tìm thấy địa chỉ mạng đang hoạt động. Hãy bật Wi-Fi, Ethernet hoặc VPN rồi quét adapter mạng trong Cài đặt.',
                    style: TextStyle(color: Color(0xFFFFB36B), fontSize: 11, height: 1.4),
                  )
                else ...[
                  const Text(
                    'CHỌN MÃ THEO ĐƯỜNG KẾT NỐI CỦA THIẾT BỊ NHẬN',
                    style: TextStyle(color: Color(0xFF67DDEC), fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  for (final target in targets) _inviteCodeTile(target['code']!, target['label']!),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Nếu hai thiết bị khác mạng Wi-Fi nhưng cùng VPN (ZeroTier/Tailscale/WireGuard), hãy sao chép mã có nhãn VPN. Với Internet thông thường, cấu hình máy chủ HTTPS/TURN trong Cài đặt trước khi tạo phòng. Ai có mã mời đều có thể tham gia trong thời hạn của phòng, vì vậy hãy giữ bí mật.',
                  style: TextStyle(color: Color(0xFF9AAAC0), fontSize: 10, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t('close')))],
      ),
    );
  }

  Widget _inviteCodeTile(String code, String label) => Container(
        margin: const EdgeInsets.only(top: 7),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1728),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF263B56)),
        ),
        child: Row(
          children: [
            const Icon(Icons.key_rounded, size: 17, color: Color(0xFF55DDF2)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Color(0xFF8FA1B9), fontSize: 9)),
                  const SizedBox(height: 3),
                  SelectableText(code, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: .3)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Sao chép mã mời',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                _showSnack('Đã sao chép mã mời MTUNZ.');
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
            ),
          ],
        ),
      );

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showJoinDialog() async {
    _codeController.clear();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('join_device_title')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Dán mã mời MTUNZ do thiết bị tạo phòng gửi cho bạn. Ứng dụng tự nhận địa chỉ máy chủ, mã phòng và PIN từ mã này.',
                style: TextStyle(color: Color(0xFF9AAAC0), fontSize: 11, height: 1.45),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 512,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Mã mời MTUNZ',
                  hintText: 'MTZ1-…',
                  alignLabelWithHint: true,
                  helperText: 'Chỉ cần một mã duy nhất',
                ),
                onSubmitted: (_) => _submitInvitationCode(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t('cancel'))),
          FilledButton(onPressed: _submitInvitationCode, child: Text(_t('connect'))),
        ],
      ),
    );
  }

  void _submitInvitationCode() {
    late final InvitationPayload invitation;
    try {
      invitation = InvitationCode.decode(_codeController.text);
    } on FormatException catch (error) {
      _showSnack(error.message.toString());
      return;
    }
    Navigator.of(context).pop();
    unawaited(_joinRoom(invitation));
  }

  bool _ensureServerConfigured() {
    final uri = Uri.tryParse(_serverUrl);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      return true;
    }
    setState(() => _selectedIndex = 3);
    _showSnack(_t('server_required'));
    return false;
  }

  bool _isThisDeviceAddress(String host) =>
      NetworkInterfaceDiscovery.isThisDeviceAddress(host, _networkEndpoints);

  Future<void> _scanNetworkInterfaces() {
    // Room creation, startup and the Settings scan button can all request a
    // scan at once. Share one Future so the invitation waits for its LAN URLs.
    final activeScan = _networkScanTask;
    if (activeScan != null) return activeScan;

    late final Future<void> scan;
    scan = _performNetworkScan().whenComplete(() {
      if (identical(_networkScanTask, scan)) _networkScanTask = null;
    });
    _networkScanTask = scan;
    return scan;
  }

  Future<void> _performNetworkScan() async {
    if (!mounted) return;
    setState(() => _networkScanBusy = true);
    try {
      final endpoints = await NetworkInterfaceDiscovery.discover();
      if (mounted) setState(() => _networkEndpoints = endpoints);
    } catch (error) {
      _showSnack(_t('operation_failed', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _networkScanBusy = false);
    }
  }

  String _networkKindLabel(NetworkLinkKind kind) {
    switch (kind) {
      case NetworkLinkKind.vpn:
        return 'VPN / ZeroTier / Tailscale';
      case NetworkLinkKind.wifi:
        return _t('network_type_wifi');
      case NetworkLinkKind.wired:
        return _t('network_type_wired');
      case NetworkLinkKind.other:
        return _t('network_type_other');
    }
  }

  void _useNetworkAddress(NetworkEndpoint endpoint) {
    if (!_embeddedCore.isRunning) {
      _showSnack('MTUNZ Core chưa sẵn sàng.');
      return;
    }
    _serverController.text = 'http://${endpoint.address}:${_embeddedCore.port}';
    _saveServer();
  }

  bool _saveServer({bool showNotice = true}) {
    final raw = _serverController.text.trim();
    final uri = Uri.tryParse(raw);
    final validScheme = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final validPort = uri != null && (!uri.hasPort || (uri.port >= 1 && uri.port <= 65535));
    if (uri == null ||
        !uri.hasScheme ||
        !validScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !validPort) {
      if (showNotice) _showSnack(_t('server_invalid'));
      return false;
    }

    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    final normalized = uri.replace(path: path).toString();
    final localHost = uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        _networkEndpoints.any((endpoint) => endpoint.address == uri.host);

    setState(() {
      _serverUrl = normalized;
      _usesEmbeddedCore =
          _embeddedCore.isRunning && uri.port == _embeddedCore.port && localHost;
    });
    if (showNotice) _showSnack(_t('server_saved'));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = [
      _buildOverview(),
      _buildDevices(),
      _buildSession(),
      _buildSettings(),
      _buildFiles(),
    ];
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (wide) _buildSideRail(),
            Expanded(
              child: Column(
                children: [
                  _buildTopBar(wide),
                  Expanded(child: IndexedStack(index: _selectedIndex, children: pages)),
                  if (_notice.isNotEmpty) _buildNoticeBar(),
                  if (!wide) _buildBottomBar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideRail() => Container(
        width: 232,
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF101C2F), Color(0xFF0A1220)]),
          border: Border(right: BorderSide(color: Color(0xFF1D2A40))),
        ),
        padding: const EdgeInsets.fromLTRB(16, 22, 12, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _brand(),
            const SizedBox(height: 38),
            _navItem(0, Icons.space_dashboard_rounded, _t('nav_overview')),
            _navItem(1, Icons.devices_rounded, _t('nav_devices')),
            _navItem(2, Icons.cast_connected_rounded, _t('nav_session')),
            _navItem(3, Icons.tune_rounded, _t('nav_settings')),
            _navItem(4, Icons.folder_copy_rounded, _t('nav_files')),
            const Spacer(),
            _connectionCard(),
          ],
        ),
      );

  Widget _brand() => Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: const LinearGradient(colors: [Color(0xFF31D6F3), Color(0xFF706BFF)]),
              boxShadow: [BoxShadow(color: const Color(0xFF31D6F3).withValues(alpha: .18), blurRadius: 22)],
            ),
            child: const Icon(Icons.hub_rounded, color: Color(0xFF07111F), size: 24),
          ),
          const SizedBox(width: 12),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MTUNZ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19, letterSpacing: 2.4)),
            Text('DEVICE NETWORK', style: TextStyle(color: Color(0xFF8393AD), fontSize: 8, letterSpacing: 1.8)),
          ]),
        ],
      );

  Widget _navItem(int index, IconData icon, String label) {
    final selected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _selectedIndex = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF13283B) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? const Color(0xFF1C5165) : Colors.transparent),
          ),
          child: Row(children: [
            Icon(icon, size: 19, color: selected ? const Color(0xFF49DDF4) : const Color(0xFF8290A7)),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: selected ? Colors.white : const Color(0xFF99A7BD), fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  Widget _connectionCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFF101F30), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1D3B50))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Icon(Icons.circle, color: Color(0xFF36D6A0), size: 8), const SizedBox(width: 8), Text(_statusText, style: const TextStyle(fontSize: 11, color: Color(0xFFB7C7D8))) ]),
          const SizedBox(height: 9),
          const Text('MTUNZ Core', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          Text(_serverUrl, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Color(0xFF70839B))),
        ]),
      );

  Widget _buildTopBar(bool wide) => Padding(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 18, 18, wide ? 28 : 18, 12),
        child: Row(children: [
          if (!wide) _brand(),
          if (!wide) const Spacer(),
          if (wide) Expanded(child: Text(_t('workspace'), style: const TextStyle(color: Color(0xFF8191A8), fontSize: 10, letterSpacing: 1.8))),
          _statusPill(),
        ]),
      );

  Widget _statusPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFF10261F), border: Border.all(color: const Color(0xFF245240)), borderRadius: BorderRadius.circular(30)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.circle, color: Color(0xFF43D7A5), size: 7), const SizedBox(width: 8), Text(_statusText, style: const TextStyle(fontSize: 11, color: Color(0xFFBAE9D7))) ]),
      );

  Widget _buildOverview() => LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth > 760;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 26),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t('overview_title'), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -.7)),
            const SizedBox(height: 8),
            Text(_t('overview_subtitle'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 13)),
            const SizedBox(height: 25),
            _heroCard(),
            const SizedBox(height: 18),
            if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: _quickActions()), const SizedBox(width: 16), Expanded(child: _connectedCard())]) else ...[_quickActions(), const SizedBox(height: 16), _connectedCard()],
            const SizedBox(height: 18),
            _featureStrip(),
          ]),
        );
      });

  Widget _heroCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF143449), Color(0xFF171C3B), Color(0xFF121A2D)]),
          border: Border.all(color: const Color(0xFF23536A)),
        ),
        child: Stack(children: [
          Positioned(right: -12, top: -22, child: Icon(Icons.hub_rounded, size: 170, color: Colors.white.withValues(alpha: .035))),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Icon(Icons.bolt_rounded, color: Color(0xFF52E1F5), size: 18), const SizedBox(width: 7), Text(_t('cross_device'), style: const TextStyle(color: Color(0xFF8EEBFA), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.6))]),
            const SizedBox(height: 18),
            Text(_t('hero_title'), style: const TextStyle(fontSize: 29, height: 1.12, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(_t('hero_subtitle'), style: const TextStyle(color: Color(0xFFB4C7D8), fontSize: 12, height: 1.5)),
            const SizedBox(height: 20),
            Wrap(spacing: 10, runSpacing: 9, children: [
              FilledButton.icon(onPressed: _busy ? null : _createRoom, icon: const Icon(Icons.add_link_rounded, size: 18), label: Text(_t('create_room'))),
              OutlinedButton.icon(onPressed: _busy ? null : _showJoinDialog, icon: const Icon(Icons.login_rounded, size: 17), label: Text(_t('enter_room'))),
            ]),
          ]),
        ]),
      );

  Widget _quickActions() => _panel(
        title: _t('quick_access'),
        subtitle: _t('common_actions'),
        child: Column(children: [
          _actionRow(Icons.cast_connected_rounded, _t('screen_share'), _t('screen_share_desc'), _sharing ? _t('sharing') : _t('start'), _sharing ? _stopShare : _startShare),
          const Divider(height: 22, color: Color(0xFF24334A)),
          _actionRow(Icons.devices_rounded, _t('nav_devices'), _t('devices_in_session', {'count': '${_peers.length}'}), _t('view'), () => setState(() => _selectedIndex = 1)),
          const Divider(height: 22, color: Color(0xFF24334A)),
          _actionRow(Icons.qr_code_2_rounded, _t('pair_device'), _t('create_invite'), _t('create_room'), _createRoom),
        ]),
      );

  Widget _connectedCard() => _panel(
        title: _t('devices_in_room'),
        subtitle: _t('room_limit_subtitle'),
        child: _peers.isEmpty
            ? Padding(padding: const EdgeInsets.symmetric(vertical: 15), child: Row(children: [const Icon(Icons.devices_other_rounded, color: Color(0xFF62748D), size: 32), const SizedBox(width: 13), Expanded(child: Text(_t('no_devices'), style: const TextStyle(color: Color(0xFF93A2B7), fontSize: 12, height: 1.45))) ]))
            : Column(children: _peers.map(_peerRow).toList()),
      );

  Widget _featureStrip() => Wrap(spacing: 10, runSpacing: 10, children: [
        _miniFeature(Icons.hd_rounded, _t('feature_webrtc')),
        _miniFeature(Icons.lock_outline_rounded, _t('feature_approval')),
        _miniFeature(Icons.hub_rounded, _t('feature_limit')),
      ]);

  Widget _miniFeature(IconData icon, String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), decoration: BoxDecoration(color: const Color(0xFF101A2A), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF223149))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 15, color: const Color(0xFF49DDF4)), const SizedBox(width: 8), Text(text, style: const TextStyle(fontSize: 10, color: Color(0xFF9EADC1))) ]));

  Widget _buildDevices() => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t('devices_title'), style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(_t('devices_subtitle'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12)),
          const SizedBox(height: 22),
          _panel(title: _t('current_session'), subtitle: _t('three_device_limit'), child: _peers.isEmpty ? Text(_t('no_remote_devices'), style: const TextStyle(color: Color(0xFF91A0B7))) : Column(children: _peers.map(_peerRow).toList())),
          const SizedBox(height: 16),
          _panel(title: _t('add_device'), subtitle: _t('temporary_room'), child: Wrap(spacing: 10, runSpacing: 10, children: [FilledButton.icon(onPressed: _createRoom, icon: const Icon(Icons.add), label: Text(_t('create_room'))), OutlinedButton.icon(onPressed: _showJoinDialog, icon: const Icon(Icons.login), label: Text(_t('join_room')))])),
        ]),
      );

  Widget _peerRow(PeerView peer) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFF172C42), borderRadius: BorderRadius.circular(12)), child: Icon(peer.name.toLowerCase().contains('android') ? Icons.smartphone_rounded : Icons.laptop_mac_rounded, color: const Color(0xFF52DDF2))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(peer.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), Text(_peerStateLabel(peer.state), style: const TextStyle(color: Color(0xFF8193AA), fontSize: 10))])),
          const Icon(Icons.circle, color: Color(0xFF41D6A0), size: 8),
        ]),
      );

  Widget _buildSession() => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t('session_title'), style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800)), const SizedBox(height: 7), Text(_t('session_subtitle'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12))])), if (_roomCode != null) OutlinedButton.icon(onPressed: _disconnect, icon: const Icon(Icons.call_end_rounded, size: 16), label: Text(_t('disconnect')))]),
          const SizedBox(height: 20),
          if (_roomCode == null) _panel(title: _t('no_session'), subtitle: _t('create_or_join'), child: Wrap(spacing: 10, children: [FilledButton(onPressed: _createRoom, child: Text(_t('create_room'))), OutlinedButton(onPressed: _showJoinDialog, child: Text(_t('join_room')))])) else ...[
            _panel(
              title: _t('room_code_title'),
              subtitle: _roomPin == null ? _t('joined_room') : 'Chia sẻ mã mời đầy đủ trong cửa sổ tạo phòng',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_roomCode!, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 3, color: Color(0xFF57E0F4))),
                  if (_roomPin != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Text(
                        'Đây là mã phòng nội bộ. Không chia sẻ PIN riêng; hãy dùng mã mời MTUNZ đầy đủ.',
                        style: TextStyle(color: Color(0xFF9AAAC0), fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: [FilledButton.icon(onPressed: _sharing ? _stopShare : _startShare, icon: Icon(_sharing ? Icons.stop_circle_outlined : Icons.screen_share_outlined), label: Text(_sharing ? _t('stop_sharing') : _t('share_this_device'))), OutlinedButton.icon(onPressed: _showJoinDialog, icon: const Icon(Icons.person_add_alt_1_rounded), label: Text(_t('add_another_device')))]),
            const SizedBox(height: 16),
            _panel(title: _t('remote_screens'), subtitle: _t('tap_after_approval'), child: _peers.isEmpty ? Padding(padding: const EdgeInsets.symmetric(vertical: 34), child: Center(child: Text(_t('waiting_peer'), style: const TextStyle(color: Color(0xFF91A0B7))))) : Column(children: _peers.map(_remoteScreenCard).toList())),
          ],
        ]),
      );

  ({double x, double y})? _mapPointToRemoteVideo(
    RTCVideoRenderer renderer,
    Offset point,
    Size viewport,
  ) {
    final sourceWidth = renderer.videoWidth.toDouble();
    final sourceHeight = renderer.videoHeight.toDouble();
    if (sourceWidth <= 0 || sourceHeight <= 0 || viewport.isEmpty) return null;

    // RTCVideoView uses contain-fit, so remove the letterbox before mapping
    // taps and swipes to the remote display's normalized coordinates.
    final scale = math.min(viewport.width / sourceWidth, viewport.height / sourceHeight);
    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;
    final left = (viewport.width - renderedWidth) / 2;
    final top = (viewport.height - renderedHeight) / 2;
    final x = (point.dx - left) / renderedWidth;
    final y = (point.dy - top) / renderedHeight;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return (x: x, y: y);
  }

  String _peerStateLabel(String state) => state.replaceFirst('RTCPeerConnectionState.', '');

  Widget _remoteScreenCard(PeerView peer) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(peer.name, style: const TextStyle(fontWeight: FontWeight.w700))), Text(_peerStateLabel(peer.state), style: const TextStyle(fontSize: 10, color: Color(0xFF90A1B8)))]),
          const SizedBox(height: 9),
          Container(
            width: double.infinity,
            height: 280,
            decoration: BoxDecoration(color: const Color(0xFF050A12), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF25374E))),
            clipBehavior: Clip.antiAlias,
            child: (!peer.isSharing || peer.renderer?.srcObject == null)
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.screen_search_desktop_rounded, size: 36, color: Color(0xFF60738D)), const SizedBox(height: 8), Text(_t('no_video'), style: const TextStyle(color: Color(0xFF8FA0B7), fontSize: 11))]))
                : LayoutBuilder(builder: (context, box) {
                    Offset? swipeStart;
                    final viewport = box.biggest;
                    return GestureDetector(
                      onTapUp: (details) {
                        final point = _mapPointToRemoteVideo(peer.renderer!, details.localPosition, viewport);
                        if (point != null) _mesh?.sendTap(peer.id, point.x, point.y);
                      },
                      onPanStart: (details) {
                        swipeStart = _mapPointToRemoteVideo(peer.renderer!, details.localPosition, viewport) == null
                            ? null
                            : details.localPosition;
                      },
                      onPanEnd: (details) {
                        final start = swipeStart;
                        swipeStart = null;
                        if (start == null) return;
                        final from = _mapPointToRemoteVideo(peer.renderer!, start, viewport);
                        final to = _mapPointToRemoteVideo(peer.renderer!, details.localPosition, viewport);
                        if (from != null && to != null) {
                          _mesh?.sendSwipe(peer.id, from.x, from.y, to.x, to.y);
                        }
                      },
                      child: RTCVideoView(peer.renderer!, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
                    );
                  }),
          ),
          const SizedBox(height: 8),
          Row(children: [OutlinedButton.icon(onPressed: () => _mesh?.requestControl(peer.id), icon: const Icon(Icons.touch_app_rounded, size: 15), label: Text(_t('request_control'))), const SizedBox(width: 8), Text(_t('approval_hint'), style: const TextStyle(color: Color(0xFF7F91A8), fontSize: 9))]),
        ]),
      );

  Widget _buildFiles() => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t('files_title'), style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(_t('files_subtitle'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12)),
          const SizedBox(height: 22),
          _panel(
            title: _t('files_transfer_title'),
            subtitle: _t('files_transfer_subtitle'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_peers.isEmpty)
                Text(_t('files_no_devices'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12))
              else ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(_selectedFilePeerId),
                  initialValue: _selectedFilePeerId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _t('files_peer_label'),
                    prefixIcon: const Icon(Icons.devices_rounded),
                  ),
                  items: _peers.map((peer) => DropdownMenuItem<String>(
                    value: peer.id,
                    child: Text(peer.name, overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (value) => setState(() => _selectedFilePeerId = value),
                ),
                const SizedBox(height: 13),
                FilledButton.icon(
                  onPressed: _filePickerBusy || !_peers.any((peer) => peer.id == _selectedFilePeerId && peer.canSendFile)
                      ? null
                      : _startFileTransfer,
                  icon: _filePickerBusy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_file_rounded, size: 18),
                  label: Text(_t('files_choose_send')),
                ),
              ],
              const SizedBox(height: 14),
              Text(_t('files_transfer_rule'), style: const TextStyle(color: Color(0xFF8FA2BA), fontSize: 10, height: 1.5)),
            ]),
          ),
          const SizedBox(height: 16),
          _panel(
            title: _t('files_history_title'),
            subtitle: _t('files_history_subtitle'),
            child: _fileTransfers.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(children: [
                      const Icon(Icons.folder_open_rounded, color: Color(0xFF687D97), size: 30),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_t('files_empty'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12))),
                    ]),
                  )
                : Column(children: _fileTransfers.map(_fileTransferCard).toList()),
          ),
        ]),
      );

  Widget _fileTransferCard(FileTransferView transfer) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
              transfer.isOutgoing ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              color: const Color(0xFF53DDF2),
              size: 18,
            ),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(transfer.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              Text(
                '${transfer.isOutgoing ? _t('files_to') : _t('files_from')} ${transfer.peerName} · ${_formatBytes(transfer.size)}',
                style: const TextStyle(color: Color(0xFF8395AD), fontSize: 10),
              ),
            ])),
            Text(_fileStatusLabel(transfer.status), style: const TextStyle(color: Color(0xFF9AB0C7), fontSize: 10)),
            if (transfer.canCancel)
              IconButton(
                tooltip: _t('files_cancel'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _mesh?.cancelFileTransfer(transfer.id),
                icon: const Icon(Icons.close_rounded, size: 17),
              ),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: transfer.progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(8),
            backgroundColor: const Color(0xFF23334A),
          ),
          const SizedBox(height: 5),
          Text('${_formatBytes(transfer.transferred)} / ${_formatBytes(transfer.size)}',
              style: const TextStyle(color: Color(0xFF7589A3), fontSize: 9)),
          const Divider(height: 18, color: Color(0xFF24334A)),
        ]),
      );

  Widget _buildSettings() => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t('settings_title'), style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(_t('settings_subtitle'), style: const TextStyle(color: Color(0xFF91A0B7), fontSize: 12)),
          const SizedBox(height: 22),
          _panel(title: _t('language_title'), subtitle: _t('language_subtitle'), child: DropdownButtonFormField<String>(
            key: ValueKey(widget.locale.languageCode),
            initialValue: widget.locale.languageCode,
            decoration: InputDecoration(labelText: _t('language_label'), prefixIcon: const Icon(Icons.translate_rounded)),
            dropdownColor: const Color(0xFF16243A),
            isExpanded: true,
            items: AppStrings.languages.entries.map((entry) => DropdownMenuItem<String>(
              value: entry.key,
              child: Text(entry.value, style: const TextStyle(fontSize: 13)),
            )).toList(),
            onChanged: (code) {
              if (code == null) return;
              widget.onLocaleChanged(Locale(code));
              _showSnack(AppStrings.text(code, 'language_saved'));
            },
          )),
          const SizedBox(height: 16),
          _panel(
            title: _t('core_title'),
            subtitle: 'CORE TÍCH HỢP · WINDOWS + ANDROID',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _embeddedCore.isRunning ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      color: _embeddedCore.isRunning ? const Color(0xFF37D6B2) : const Color(0xFFFF7786),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _coreStarting
                            ? 'Đang khởi động MTUNZ Core…'
                            : _embeddedCore.isRunning
                                ? 'Core đang chạy trong ứng dụng · cổng ${_embeddedCore.port}'
                                : 'Core chưa hoạt động',
                        style: const TextStyle(fontSize: 11, color: Color(0xFFB8C9DE)),
                      ),
                    ),
                    if (!_embeddedCore.isRunning)
                      TextButton(onPressed: _coreStarting ? null : _startEmbeddedCore, child: const Text('Thử lại')),
                  ],
                ),
                if (_coreError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_coreError!, style: const TextStyle(color: Color(0xFFFF8895), fontSize: 10)),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serverController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: _t('server_address'), hintText: 'http://192.168.1.20:${_embeddedCore.port == 0 ? 8787 : _embeddedCore.port}'),
                ),
                const SizedBox(height: 10),
                FilledButton(onPressed: _saveServer, child: Text(_t('save_address'))),
                const SizedBox(height: 8),
                const Text(
                  'Core được tích hợp và tự khởi động cùng MTUNZ. Để dùng LAN/VPN, giữ địa chỉ Core nội bộ. Để kết nối qua Internet khác mạng, nhập URL máy chủ signaling HTTPS đã triển khai kèm TURN tại đây rồi lưu một lần. Khi tạo phòng, mã mời sẽ tự chứa URL đó; thiết bị nhận chỉ cần nhập một mã.',
                  style: TextStyle(color: Color(0xFF8698B0), fontSize: 10, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _panel(
            title: _t('network_links_title'),
            subtitle: _t('network_links_subtitle'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: _networkScanBusy ? null : _scanNetworkInterfaces,
                    // The Settings page is kept alive in an IndexedStack.
                    // An indeterminate spinner here prevents the whole widget
                    // tree from ever settling in automated tests and can keep
                    // hidden pages animating in the background.
                    icon: const Icon(Icons.radar_rounded, size: 17),
                    label: Text(_t('network_scan')),
                  ),
                ),
                if (_networkEndpoints.isEmpty && !_networkScanBusy)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_t('network_none'), style: const TextStyle(color: Color(0xFF8FA1B9), fontSize: 11)),
                  ),
                for (final endpoint in _networkEndpoints)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1728),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF263B56)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          endpoint.kind == NetworkLinkKind.vpn
                              ? Icons.vpn_key_rounded
                              : endpoint.kind == NetworkLinkKind.wired
                                  ? Icons.cable_rounded
                                  : endpoint.kind == NetworkLinkKind.wifi
                                      ? Icons.wifi_rounded
                                      : Icons.lan_rounded,
                          color: const Color(0xFF55DDF2),
                          size: 19,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(endpoint.interfaceName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              Text(
                                '${_networkKindLabel(endpoint.kind)} · ${endpoint.address}:${_embeddedCore.port}',
                                style: const TextStyle(fontSize: 10, color: Color(0xFF8FA1B9)),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => _useNetworkAddress(endpoint),
                          child: Text(_t('network_use_address'), style: const TextStyle(fontSize: 10)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Chọn địa chỉ LAN của thiết bị đang tạo phòng. Android USB tethering chỉ hoạt động khi Windows nhìn thấy adapter RNDIS và hai thiết bị định tuyến được tới nhau.',
                  style: TextStyle(color: Color(0xFF9AAAC0), fontSize: 10, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _panel(title: _t('security_title'), subtitle: _t('security_subtitle'), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_t('accessibility_help'), style: const TextStyle(color: Color(0xFF9AAAC0), fontSize: 11, height: 1.5)), const SizedBox(height: 12), OutlinedButton.icon(onPressed: Platform.isAndroid ? PlatformController.openAccessibilitySettings : null, icon: const Icon(Icons.accessibility_new_rounded), label: Text(_t('open_accessibility')))])),
          const SizedBox(height: 16),
          _panel(title: _t('version_title'), subtitle: _t('version_subtitle'), child: Row(children: [const Text('MTUNZ', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5)), const Spacer(), Text(_t('development_build'), style: const TextStyle(color: Color(0xFF8FA1B9), fontSize: 10))])),
        ]),
      );

  Widget _panel({required String title, required String subtitle, required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF142137), Color(0xFF101827)]),
          border: Border.all(color: const Color(0xFF293A55)),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .16), blurRadius: 22, offset: const Offset(0, 9))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 10, letterSpacing: 1.4, color: Color(0xFF67DDEC), fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(subtitle, style: const TextStyle(fontSize: 10, color: Color(0xFF8294AC))),
          const SizedBox(height: 15),
          child,
        ]),
      );

  Widget _actionRow(IconData icon, String title, String detail, String action, VoidCallback onTap) => Row(children: [Container(width: 38, height: 38, decoration: BoxDecoration(color: const Color(0xFF172C42), borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: const Color(0xFF56DDF3), size: 19)), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)), Text(detail, style: const TextStyle(fontSize: 10, color: Color(0xFF8395AD)))])), TextButton(onPressed: onTap, child: Text(action))]);

  Widget _buildNoticeBar() => Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), decoration: const BoxDecoration(color: Color(0xFF0D1727), border: Border(top: BorderSide(color: Color(0xFF1E2B40)))), child: Row(children: [const Icon(Icons.info_outline_rounded, color: Color(0xFF4DDCF2), size: 14), const SizedBox(width: 8), Expanded(child: Text(_noticeIsKey ? _t(_notice) : _notice, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF92A3B9), fontSize: 10))) ]));

  Widget _buildBottomBar() => NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        backgroundColor: const Color(0xFF0C1423),
        indicatorColor: const Color(0xFF18374A),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.space_dashboard_outlined), selectedIcon: const Icon(Icons.space_dashboard), label: _t('nav_overview')),
          NavigationDestination(icon: const Icon(Icons.devices_outlined), selectedIcon: const Icon(Icons.devices), label: _t('nav_devices')),
          NavigationDestination(icon: const Icon(Icons.cast_connected_outlined), selectedIcon: const Icon(Icons.cast_connected), label: _t('nav_session')),
          NavigationDestination(icon: const Icon(Icons.tune_outlined), selectedIcon: const Icon(Icons.tune), label: _t('nav_settings')),
          NavigationDestination(icon: const Icon(Icons.folder_copy_outlined), selectedIcon: const Icon(Icons.folder_copy), label: _t('nav_files')),
        ],
      );
}

class _CodeTile extends StatelessWidget {
  const _CodeTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFF0B1422), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF263951))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Color(0xFF7F95AE), fontSize: 9, letterSpacing: 1.4)), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 22, letterSpacing: 3, fontWeight: FontWeight.w900, color: Color(0xFF5BE2F5)))]),
      );
}
