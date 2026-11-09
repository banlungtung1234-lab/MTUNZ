import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_strings.dart';

import 'services/platform_controller.dart';
import 'services/rtc_mesh.dart';
import 'services/signaling_client.dart';

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
  final _serverController = TextEditingController(text: Platform.isAndroid ? '' : 'http://127.0.0.1:8787');
  final _codeController = TextEditingController();
  final _pinController = TextEditingController();
  int _selectedIndex = 0;
  String _serverUrl = Platform.isAndroid ? '' : 'http://127.0.0.1:8787';
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

  String _t(String key, [Map<String, String> values = const {}]) =>
      AppStrings.text(widget.locale.languageCode, key, values);

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    _pinController.dispose();
    unawaited(_disconnect().catchError((_) {}));
    super.dispose();
  }

  Future<void> _createRoom() async {
    if (!_ensureServerConfigured()) return;
    await _withBusy(() async {
      await _disconnect();
      final client = _newClient();
      var attached = false;
      try {
        final invite = await client.createRoom();
        final joined = await client.joinRoom(invite.code, invite.pin);
        if (!mounted) {
          await client.leave();
          return;
        }
        _attach(client, joined.peers);
        attached = true;
        setState(() {
          _roomCode = invite.code;
          _roomPin = invite.pin;
          _statusKey = 'status_waiting';
          _notice = 'notice_room_ready';
          _noticeIsKey = true;
        });
        _showInvite(invite);
      } catch (_) {
        if (!attached) await client.leave();
        rethrow;
      }
    });
  }

  Future<void> _joinRoom() async {
    if (!_ensureServerConfigured()) return;
    final code = _codeController.text.trim().toUpperCase();
    final pin = _pinController.text.trim();
    if (code.length != 8 || pin.length != 6) {
      _showSnack(_t('join_format_error'));
      return;
    }
    await _withBusy(() async {
      await _disconnect();
      final client = _newClient();
      var attached = false;
      try {
        final joined = await client.joinRoom(code, pin);
        if (!mounted) {
          await client.leave();
          return;
        }
        _attach(client, joined.peers);
        attached = true;
        setState(() {
          _roomCode = code;
          _roomPin = null;
          _statusKey = 'status_joined';
          _notice = 'notice_signaling_connected';
          _noticeIsKey = true;
          _selectedIndex = 2;
        });
        _showSnack(_t('join_success', {'code': code}));
      } catch (_) {
        if (!attached) await client.leave();
        rethrow;
      }
    });
  }

  SignalingClient _newClient() => SignalingClient(
        serverUrl: _serverUrl,
        deviceName: Platform.isAndroid ? 'MTUNZ Android' : 'MTUNZ Windows',
      );

  void _attach(SignalingClient client, List<Map<String, dynamic>> existingPeers) {
    _signaling = client;
    _mesh = RtcMesh(
      signaling: client,
      onChanged: (peers) {
        if (!mounted) return;
        setState(() {
          _peers = peers;
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
    );
    unawaited(_mesh!.handleExistingPeers(existingPeers));
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

  void _showInvite(RoomInvite invite) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('room_created')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('invite_instructions')),
            const SizedBox(height: 18),
            _CodeTile(label: _t('room_code'), value: invite.code),
            const SizedBox(height: 10),
            _CodeTile(label: _t('invite_pin'), value: invite.pin),
            const SizedBox(height: 10),
            Text(_t('room_expires', {'minutes': '${invite.expiresInSeconds ~/ 60}'}), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60)),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t('close')))],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showJoinDialog() async {
    _codeController.clear();
    _pinController.clear();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('join_device_title')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _codeController, textCapitalization: TextCapitalization.characters, maxLength: 8, decoration: InputDecoration(labelText: _t('room_code'), hintText: _t('room_code_hint'))),
              const SizedBox(height: 10),
              TextField(controller: _pinController, keyboardType: TextInputType.number, maxLength: 6, decoration: InputDecoration(labelText: _t('invite_pin'), hintText: _t('pin_hint'))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t('cancel'))),
          FilledButton(onPressed: () { Navigator.pop(context); unawaited(_joinRoom()); }, child: Text(_t('connect'))),
        ],
      ),
    );
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

  void _saveServer() {
    final raw = _serverController.text.trim();
    final uri = Uri.tryParse(raw);
    final validScheme = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final validPort = uri != null && (!uri.hasPort || (uri.port >= 1 && uri.port <= 65535));
    if (uri == null || !uri.hasScheme || !validScheme || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment || !validPort) {
      _showSnack(_t('server_invalid'));
      return;
    }
    final normalized = uri.replace(path: uri.path.replaceFirst(RegExp(r'/$'), '')).toString();
    setState(() => _serverUrl = normalized);
    _showSnack(_t('server_saved'));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = [
      _buildOverview(),
      _buildDevices(),
      _buildSession(),
      _buildSettings(),
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
            _panel(title: _t('room_code_title'), subtitle: _roomPin == null ? _t('joined_room') : _t('share_codes'), child: Row(children: [Text(_roomCode!, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 3, color: Color(0xFF57E0F4))), const Spacer(), if (_roomPin != null) Text('PIN $_roomPin', style: const TextStyle(color: Color(0xFFC3B7FF), fontWeight: FontWeight.w800))])),
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
          _panel(title: _t('core_title'), subtitle: _t('core_subtitle'), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [TextField(controller: _serverController, decoration: InputDecoration(labelText: _t('server_address'), hintText: 'http://192.168.1.10:8787')), const SizedBox(height: 10), FilledButton(onPressed: _saveServer, child: Text(_t('save_address'))), const SizedBox(height: 8), Text(_t('server_help'), style: const TextStyle(color: Color(0xFF8698B0), fontSize: 10, height: 1.5))])),
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
