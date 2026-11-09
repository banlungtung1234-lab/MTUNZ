import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'platform_controller.dart';
import 'signaling_client.dart';

class PeerView {
  const PeerView({required this.id, required this.name, required this.state, required this.isSharing, this.renderer});
  final String id;
  final String name;
  final String state;
  final bool isSharing;
  final RTCVideoRenderer? renderer;
}

class RtcMesh {
  RtcMesh({
    required this.signaling,
    required this.onChanged,
    required this.onControlRequest,
    required this.onNotice,
    required this.onSharingChanged,
  }) {
    _subscription = signaling.events.listen(
      _queueSignalMessage,
      onError: (Object error) {
        if (!_disposed) onNotice('Lỗi nhận tín hiệu: $error');
      },
    );
  }

  final SignalingClient signaling;
  final void Function(List<PeerView> peers) onChanged;
  final Future<void> Function(String peerId, String peerName) onControlRequest;
  final void Function(String message) onNotice;
  final void Function(bool sharing) onSharingChanged;
  final Map<String, _PeerLink> _links = {};
  final Map<String, Future<_PeerLink>> _linkCreations = {};
  final Map<String, String> _peerNames = {};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void> _signalQueue = Future<void>.value();
  MediaStream? _localScreen;
  bool _disposed = false;

  List<PeerView> get peers => _links.values
      .map((link) => PeerView(
            id: link.id,
            name: _peerNames[link.id] ?? 'Thiết bị ${link.id.substring(0, link.id.length < 4 ? link.id.length : 4)}',
            state: link.state,
            isSharing: link.remoteSharing,
            renderer: link.renderer,
          ))
      .toList(growable: false);

  Future<void> handleExistingPeers(List<Map<String, dynamic>> peers) async {
    try {
      for (final peer in peers) {
        if (_disposed) return;
        final id = peer['id'] as String?;
        if (id == null || id == signaling.peerId || id.length < 8 || id.length > 80) continue;
        _peerNames[id] = peer['name'] as String? ?? 'MTUNZ device';
        await _ensureLink(id);
        if (signaling.peerId.compareTo(id) < 0) await _makeOffer(id);
      }
      _notify();
    } catch (error) {
      if (!_disposed) onNotice('Không thể thiết lập liên kết thiết bị: $error');
    }
  }

  Future<void> startScreenShare() async {
    if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');
    if (_localScreen != null) return;
    var projectionServiceStarted = false;
    MediaStream? stream;
    try {
      if (WebRTC.platformIsAndroid) {
        // Android requires a fresh system consent for every MediaProjection.
        // After consent, start the mediaProjection foreground service before
        // asking flutter_webrtc to consume the approved projection.
        final approved = await Helper.requestCapturePermission(fullScreenOnly: true);
        if (!approved) {
          throw StateError('Bạn chưa cho phép MTUNZ chia sẻ màn hình.');
        }
        await PlatformController.startMediaProjectionService();
        projectionServiceStarted = true;
      }

      stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'mandatory': {'frameRate': 30.0, 'maxWidth': 1920, 'maxHeight': 1080},
        },
        'audio': false,
      });
      if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');
      final videoTracks = stream.getVideoTracks();
      if (videoTracks.isEmpty) throw StateError('Không nhận được luồng hình ảnh từ thiết bị.');
      final screenTrack = videoTracks.first;
      _localScreen = stream;
      onSharingChanged(true);
      screenTrack.onEnded = () {
        if (identical(_localScreen, stream) && !_disposed) {
          unawaited(_handleExternalScreenStop(stream!));
        }
      };
      for (final link in _links.values.toList(growable: false)) {
        if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');
        if (link.screenSender == null) {
          link.screenSender = await link.connection.addTrack(screenTrack, stream);
          if (signaling.peerId.compareTo(link.id) < 0) {
            await _makeOffer(link.id, force: true);
          } else {
            await signaling.sendSignal(link.id, 'renegotiate-request', const {});
          }
        } else {
          // Reuse the existing video sender on subsequent shares. This avoids
          // accumulating extra video transceivers every time sharing restarts.
          await link.screenSender!.replaceTrack(screenTrack);
          await link.screenSender!.setStreams([stream]);
        }
        _sendData(link, {'type': 'screen-share-status', 'sharing': true});
      }
      onNotice('Đã bắt đầu chia sẻ màn hình. Người nhận cần chấp thuận quyền điều khiển riêng.');
    } catch (_) {
      if (identical(_localScreen, stream)) _localScreen = null;
      onSharingChanged(false);
      if (stream != null) {
        for (final track in stream.getTracks()) {
          try {
            await track.stop();
          } catch (_) {
            // Continue cleanup for the remaining tracks.
          }
        }
        try {
          await stream.dispose();
        } catch (_) {
          // Native capture may already have disposed the stream.
        }
      }
      if (projectionServiceStarted) {
        try {
          await PlatformController.stopMediaProjectionService();
        } catch (_) {
          // Do not hide the original capture error.
        }
      }
      rethrow;
    }
  }

  Future<void> stopScreenShare() async {
    final stream = _localScreen;
    if (stream == null) return;
    _localScreen = null;
    onSharingChanged(false);
    Object? firstError;
    for (final link in _links.values) {
      _sendData(link, {'type': 'screen-share-status', 'sharing': false});
    }
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (error) {
        firstError ??= error;
      }
    }
    try {
      await stream.dispose();
    } catch (error) {
      firstError ??= error;
    }
    if (WebRTC.platformIsAndroid) {
      try {
        await PlatformController.stopMediaProjectionService();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (!_disposed) onNotice('Đã dừng chia sẻ màn hình.');
    if (firstError != null) throw StateError('Không dừng được toàn bộ tài nguyên chia sẻ: $firstError');
  }

  Future<void> _handleExternalScreenStop(MediaStream stream) async {
    if (!identical(_localScreen, stream)) return;
    _localScreen = null;
    onSharingChanged(false);
    for (final link in _links.values) {
      _sendData(link, {'type': 'screen-share-status', 'sharing': false});
    }
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {
        // System capture may already have ended the track.
      }
    }
    try {
      await stream.dispose();
    } catch (_) {
      // The native capturer may already have released it.
    }
    if (WebRTC.platformIsAndroid) {
      try {
        await PlatformController.stopMediaProjectionService();
      } catch (_) {
        if (!_disposed) onNotice('Không dừng được dịch vụ chia sẻ màn hình Android.');
      }
    }
    if (!_disposed) onNotice('Chia sẻ màn hình đã kết thúc từ hệ thống.');
  }

  Future<void> requestControl(String peerId) async {
    final channel = _links[peerId]?.dataChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      onNotice('Kênh điều khiển chưa sẵn sàng.');
      return;
    }
    channel.send(RTCDataChannelMessage(jsonEncode({'type': 'control-request'})));
    onNotice('Đã gửi yêu cầu điều khiển. Chờ thiết bị kia chấp thuận.');
  }

  Future<void> setRemoteControlPermission(String peerId, bool allowed) async {
    final link = _links[peerId];
    if (link == null) return;
    link.allowIncomingControl = allowed;
    final channel = link.dataChannel;
    if (channel != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      channel.send(RTCDataChannelMessage(jsonEncode({'type': allowed ? 'control-grant' : 'control-revoke'})));
    }
    _notify();
  }

  void sendTap(String peerId, double normalizedX, double normalizedY) {
    final link = _links[peerId];
    if (link == null || !link.remoteGrantedControl) return;
    _sendData(link, {
      'type': 'gesture',
      'action': 'tap',
      'x': normalizedX.clamp(0.0, 1.0),
      'y': normalizedY.clamp(0.0, 1.0),
    });
  }

  void sendSwipe(String peerId, double x, double y, double endX, double endY) {
    final link = _links[peerId];
    if (link == null || !link.remoteGrantedControl) return;
    _sendData(link, {
      'type': 'gesture',
      'action': 'swipe',
      'x': x.clamp(0.0, 1.0),
      'y': y.clamp(0.0, 1.0),
      'endX': endX.clamp(0.0, 1.0),
      'endY': endY.clamp(0.0, 1.0),
      'durationMs': 350,
    });
  }

  void _queueSignalMessage(Map<String, dynamic> message) {
    // Preserve signaling order: a peer-left event must not overtake an offer
    // that was queued earlier for the same device.
    _signalQueue = _signalQueue.then((_) => _handleSignalMessage(message));
  }

  Future<void> _handleSignalMessage(Map<String, dynamic> message) async {
    try {
      await _processSignalMessage(message);
    } catch (error) {
      if (!_disposed) onNotice('Lỗi xử lý tín hiệu từ thiết bị khác: $error');
    }
  }

  bool _isValidPeerId(String? id) =>
      id != null && id != signaling.peerId && id.length >= 8 && id.length <= 80;

  Future<void> _processSignalMessage(Map<String, dynamic> message) async {
    if (_disposed) return;
    final type = message['type'] as String?;
    if (type == 'room-expired') {
      onNotice('Phòng đã hết hạn. Hãy tạo phòng mới.');
      return;
    }
    if (type == 'connection-warning') {
      onNotice('Mạng tín hiệu đang gián đoạn; MTUNZ sẽ tự động thử kết nối lại.');
      return;
    }
    if (type == 'connection-restored') {
      onNotice('Kết nối tín hiệu đã được khôi phục.');
      return;
    }
    if (type == 'session-error') {
      final status = message['statusCode'];
      final detail = message['message'] as String? ?? '';
      onNotice('Phiên tín hiệu không còn hợp lệ (HTTP $status). Hãy ngắt phiên và kết nối lại. $detail');
      return;
    }
    if (type == 'peer-joined') {
      final peer = message['peer'] as Map<String, dynamic>?;
      if (peer == null) return;
      final id = peer['id'] as String?;
      if (!_isValidPeerId(id)) return;
      _peerNames[id!] = peer['name'] as String? ?? 'MTUNZ device';
      await _ensureLink(id);
      if (signaling.peerId.compareTo(id) < 0) await _makeOffer(id);
      _notify();
      return;
    }
    if (type == 'peer-left') {
      final id = message['peerId'] as String?;
      if (_isValidPeerId(id)) await _removeLink(id!);
      _notify();
      return;
    }
    if (type == 'renegotiate-request') {
      final from = message['from'] as String?;
      if (_isValidPeerId(from) && signaling.peerId.compareTo(from!) < 0) {
        await _makeOffer(from, force: true);
      }
      return;
    }
    if (type != 'offer' && type != 'answer' && type != 'candidate') return;
    final from = message['from'] as String?;
    final data = message['data'] as Map<String, dynamic>?;
    if (!_isValidPeerId(from) || data == null) return;
    final link = await _ensureLink(from!);
    if (type == 'offer') {
      final sdp = data['sdp'] as String?;
      if (sdp == null) return;
      await link.connection.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      link.remoteDescriptionSet = true;
      await _drainCandidates(link);
      final answer = await link.connection.createAnswer();
      await link.connection.setLocalDescription(answer);
      await signaling.sendSignal(from, 'answer', {'sdp': answer.sdp, 'type': answer.type});
    } else if (type == 'answer') {
      final sdp = data['sdp'] as String?;
      if (sdp != null) {
        await link.connection.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        link.remoteDescriptionSet = true;
        await _drainCandidates(link);
      }
    } else {
      final candidate = data['candidate'] as String?;
      if (candidate != null) {
        final ice = RTCIceCandidate(candidate, data['sdpMid'] as String?, data['sdpMLineIndex'] as int?);
        if (link.remoteDescriptionSet) {
          await link.connection.addCandidate(ice);
        } else {
          link.pendingCandidates.add(ice);
        }
      }
    }
  }

  Future<_PeerLink> _ensureLink(String peerId) async {
    if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');
    final existing = _links[peerId];
    if (existing != null) return existing;
    final pending = _linkCreations[peerId];
    if (pending != null) return pending;

    final creation = _createLink(peerId);
    _linkCreations[peerId] = creation;
    try {
      return await creation;
    } finally {
      if (identical(_linkCreations[peerId], creation)) {
        _linkCreations.remove(peerId);
      }
    }
  }

  Future<_PeerLink> _createLink(String peerId) async {
    final renderer = RTCVideoRenderer();
    RTCPeerConnection? connection;
    try {
      await renderer.initialize();
      if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');

      final configuration = <String, dynamic>{
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      };
      connection = await createPeerConnection(configuration);
      if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');

      final link = _PeerLink(id: peerId, connection: connection, renderer: renderer);
      _links[peerId] = link;
      connection.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _disposed || _links[peerId] != link) return;
        signaling.sendSignal(peerId, 'candidate', candidate.toMap()).catchError((error) {
          if (!_disposed) onNotice('Không gửi được ICE candidate: $error');
        });
      };
      connection.onTrack = (event) {
        if (_disposed || _links[peerId] != link) return;
        if (event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
          link.remoteSharing = true;
          link.state = 'Đang truyền hình ảnh';
          _notify();
        }
      };
      connection.onConnectionState = (state) {
        if (_disposed || _links[peerId] != link) return;
        link.state = state.toString().replaceFirst('RTCPeerConnectionState.', '');
        _notify();
      };
      connection.onDataChannel = (channel) {
        if (!_disposed && _links[peerId] == link) _bindDataChannel(link, channel);
      };
      if (_localScreen != null) {
        final videoTracks = _localScreen!.getVideoTracks();
        if (videoTracks.isNotEmpty) {
          link.screenSender = await connection.addTrack(videoTracks.first, _localScreen!);
        }
      }
      return link;
    } catch (_) {
      _links.remove(peerId);
      if (connection != null) {
        try {
          await connection.close();
        } catch (_) {}
        try {
          await connection.dispose();
        } catch (_) {}
      }
      try {
        await renderer.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _makeOffer(String peerId, {bool force = false}) async {
    final link = await _ensureLink(peerId);
    if (link.makingOffer || (link.offerCreated && !force)) return;
    if (link.connection.signalingState != RTCSignalingState.RTCSignalingStateStable) return;
    link.makingOffer = true;
    try {
      if (link.dataChannel == null) {
        final channel = await link.connection.createDataChannel(
          'mtunz-control',
          RTCDataChannelInit()..ordered = true,
        );
        _bindDataChannel(link, channel);
      }
      final offer = await link.connection.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': true,
      });
      await link.connection.setLocalDescription(offer);
      await signaling.sendSignal(peerId, 'offer', {'sdp': offer.sdp, 'type': offer.type});
      link.offerCreated = true;
    } finally {
      link.makingOffer = false;
    }
  }

  void _bindDataChannel(_PeerLink link, RTCDataChannel channel) {
    link.dataChannel = channel;
    channel.onMessage = (message) async {
      if (message.isBinary) return;
      try {
        final payload = jsonDecode(message.text) as Map<String, dynamic>;
        final type = payload['type'] as String?;
        if (type == 'control-request') {
          await onControlRequest(link.id, _peerNames[link.id] ?? 'Thiết bị từ xa');
        } else if (type == 'control-grant') {
          link.remoteGrantedControl = true;
          _notify();
          onNotice('Thiết bị từ xa đã cho phép điều khiển.');
        } else if (type == 'control-revoke') {
          link.remoteGrantedControl = false;
          _notify();
          onNotice('Quyền điều khiển đã bị thu hồi.');
        } else if (type == 'screen-share-status') {
          link.remoteSharing = payload['sharing'] == true;
          if (!link.remoteSharing) link.renderer.srcObject = null;
          link.state = link.remoteSharing ? 'Đang truyền hình ảnh' : 'Đã dừng chia sẻ màn hình';
          _notify();
        } else if (type == 'gesture' && link.allowIncomingControl) {
          await PlatformController.dispatchGesture(
            action: payload['action'] as String? ?? 'tap',
            x: (payload['x'] as num?)?.toDouble() ?? 0,
            y: (payload['y'] as num?)?.toDouble() ?? 0,
            endX: (payload['endX'] as num?)?.toDouble() ?? 0,
            endY: (payload['endY'] as num?)?.toDouble() ?? 0,
            durationMs: payload['durationMs'] as int? ?? 350,
          );
        }
      } catch (_) {
        onNotice('Đã bỏ qua một lệnh điều khiển không hợp lệ.');
      }
    };
  }


  Future<void> _drainCandidates(_PeerLink link) async {
    final pending = List<RTCIceCandidate>.from(link.pendingCandidates);
    link.pendingCandidates.clear();
    for (final candidate in pending) {
      await link.connection.addCandidate(candidate);
    }
  }

  void _sendData(_PeerLink link, Map<String, dynamic> data) {
    final channel = link.dataChannel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      channel.send(RTCDataChannelMessage(jsonEncode(data)));
    } catch (error) {
      if (!_disposed) onNotice('Không gửi được thao tác tới thiết bị: $error');
    }
  }

  Future<void> _removeLink(String peerId) async {
    final pending = _linkCreations[peerId];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // A peer can disappear while its connection is being initialized.
      }
    }
    final link = _links.remove(peerId);
    _peerNames.remove(peerId);
    if (link == null) return;
    try {
      await link.connection.close();
    } finally {
      try {
        await link.connection.dispose();
      } finally {
        await link.renderer.dispose();
      }
    }
  }

  void _notify() {
    if (!_disposed) onChanged(peers);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    final pending = _linkCreations.values.toList(growable: false);
    for (final creation in pending) {
      try {
        await creation;
      } catch (_) {
        // _createLink disposes partially initialized native resources.
      }
    }
    try {
      await stopScreenShare();
    } catch (_) {
      // Keep disposing peer connections even if native capture cleanup fails.
    }
    for (final peerId in _links.keys.toList()) {
      try {
        await _removeLink(peerId);
      } catch (_) {
        // Continue releasing the remaining native connections.
      }
    }
  }
}

class _PeerLink {
  _PeerLink({required this.id, required this.connection, required this.renderer});
  final String id;
  final RTCPeerConnection connection;
  final RTCVideoRenderer renderer;
  RTCDataChannel? dataChannel;
  RTCRtpSender? screenSender;
  String state = 'Đang ghép nối';
  bool offerCreated = false;
  bool makingOffer = false;
  bool allowIncomingControl = false;
  bool remoteGrantedControl = false;
  bool remoteDescriptionSet = false;
  bool remoteSharing = false;
  final List<RTCIceCandidate> pendingCandidates = [];
}
