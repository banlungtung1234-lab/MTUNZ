import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'file_transfer_protocol.dart';
import 'platform_controller.dart';
import 'signaling_client.dart';

class PeerView {
  const PeerView({required this.id, required this.name, required this.state, required this.isSharing, required this.canSendFile, this.renderer});
  final String id;
  final String name;
  final String state;
  final bool isSharing;
  final bool canSendFile;
  final RTCVideoRenderer? renderer;
}

class FileTransferView {
  const FileTransferView({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.size,
    required this.transferred,
    required this.isOutgoing,
    required this.status,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String fileName;
  final int size;
  final int transferred;
  final bool isOutgoing;
  final String status;

  double get progress => size == 0 ? (status == 'completed' ? 1.0 : 0.0) : (transferred / size).clamp(0.0, 1.0);
  bool get canCancel => const {'waiting', 'sending', 'receiving'}.contains(status);

  FileTransferView copyWith({int? transferred, String? status}) => FileTransferView(
        id: id,
        peerId: peerId,
        peerName: peerName,
        fileName: fileName,
        size: size,
        transferred: transferred ?? this.transferred,
        isOutgoing: isOutgoing,
        status: status ?? this.status,
      );
}

class RtcMesh {
  RtcMesh({
    required this.signaling,
    required this.onChanged,
    required this.onControlRequest,
    required this.onNotice,
    required this.onSharingChanged,
    required this.onFileOffer,
    required this.onFileReceived,
    required this.onFileTransfersChanged,
    this.iceServers = const [],
  }) {
    _subscription = signaling.events.listen(
      _queueSignalMessage,
      onError: (Object error) {
        if (!_disposed) onNotice('Lỗi nhận tín hiệu: $error');
      },
    );
  }

  final SignalingClient signaling;
  final List<Map<String, dynamic>> iceServers;
  final void Function(List<PeerView> peers) onChanged;
  final Future<void> Function(String peerId, String peerName) onControlRequest;
  final void Function(String message) onNotice;
  final void Function(bool sharing) onSharingChanged;
  final Future<bool> Function(String peerId, String peerName, String fileName, int size) onFileOffer;
  final Future<bool> Function(String peerName, String fileName, Uint8List bytes) onFileReceived;
  final void Function(List<FileTransferView> transfers) onFileTransfersChanged;
  final Map<String, _PeerLink> _links = {};
  final Map<String, _OutgoingFileTransfer> _outgoingTransfers = {};
  final Map<String, _IncomingFileTransfer> _incomingTransfers = {};
  // Received files are assembled in memory; serialize receive/save operations
  // so remote peers cannot each allocate up to 100 MB at the same time.
  int _savingIncomingTransfers = 0;
  final Map<String, FileTransferView> _fileTransfers = {};
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
            canSendFile: link.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen,
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

  Future<void> sendFile({
    required String peerId,
    required String fileName,
    required int size,
    required Stream<Uint8List> content,
  }) async {
    if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');
    if (size < 0 || size > FileTransferProtocol.maxFileBytes) {
      throw StateError('Tệp vượt quá giới hạn 100 MB.');
    }
    final link = _links[peerId];
    final channel = link?.dataChannel;
    if (link == null || channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Kênh truyền tệp chưa sẵn sàng.');
    }
    if (_outgoingTransfers.values.any((transfer) => transfer.peerId == peerId)) {
      throw StateError('Đang có một tệp khác được gửi tới thiết bị này.');
    }

    final id = _newTransferId();
    final safeName = FileTransferProtocol.sanitizeFileName(fileName);
    final transfer = _OutgoingFileTransfer(id: id, peerId: peerId);
    _outgoingTransfers[id] = transfer;
    _recordFileTransfer(FileTransferView(
      id: id,
      peerId: peerId,
      peerName: _peerNames[peerId] ?? 'MTUNZ device',
      fileName: safeName,
      size: size,
      transferred: 0,
      isOutgoing: true,
      status: 'waiting',
    ));

    try {
      await channel.send(RTCDataChannelMessage(jsonEncode({
        'type': 'file-offer',
        'transferId': id,
        'name': safeName,
        'size': size,
      })));
      final accepted = await transfer.accepted.future.timeout(const Duration(seconds: 90));
      if (!accepted || transfer.cancelled) {
        throw StateError('Thiết bị nhận đã từ chối hoặc hủy nhận tệp.');
      }

      _updateFileTransfer(id, status: 'sending');
      var sentBytes = 0;
      var lastProgressBytes = 0;
      var chunkIndex = 0;
      await for (final block in content) {
        for (var offset = 0; offset < block.length; offset += FileTransferProtocol.chunkBytes) {
          if (transfer.cancelled || _disposed) throw StateError('Truyền tệp đã bị hủy.');
          final end = math.min(offset + FileTransferProtocol.chunkBytes, block.length);
          final payload = Uint8List.sublistView(block, offset, end);
          if (sentBytes + payload.length > size) {
            throw StateError('Dữ liệu tệp đọc được lớn hơn kích thước đã khai báo.');
          }
          final packet = FileTransferProtocol.encodeChunk(
            transferId: id,
            index: chunkIndex,
            payload: payload,
          );
          await _sendFilePacket(channel, packet, isCancelled: () => transfer.cancelled || _disposed);
          sentBytes += payload.length;
          chunkIndex++;
          if (sentBytes - lastProgressBytes >= 1024 * 1024 || sentBytes == size) {
            lastProgressBytes = sentBytes;
            _updateFileTransfer(id, transferred: sentBytes);
          }
        }
      }
      if (sentBytes != size) {
        throw StateError('Kích thước tệp đọc được không khớp với thông tin ban đầu.');
      }
      await channel.send(RTCDataChannelMessage(jsonEncode({'type': 'file-complete', 'transferId': id})));
      _updateFileTransfer(id, status: 'sent');
    } catch (error) {
      _sendData(link, {'type': 'file-cancel', 'transferId': id});
      _updateFileTransfer(id, status: transfer.cancelled ? 'cancelled' : transfer.rejected ? 'rejected' : 'failed');
      rethrow;
    } finally {
      _outgoingTransfers.remove(id);
    }
  }

  static const int _fileChannelHighWaterBytes = 4 * 1024 * 1024;
  static const int _fileChannelLowWaterBytes = 2 * 1024 * 1024;

  Future<void> _sendFilePacket(
    RTCDataChannel channel,
    Uint8List packet, {
    required bool Function() isCancelled,
  }) async {
    var buffered = await channel.getBufferedAmount();
    if (buffered >= _fileChannelHighWaterBytes) {
      while (buffered > _fileChannelLowWaterBytes) {
        if (isCancelled()) throw StateError('Truyền tệp đã bị hủy.');
        if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
          throw StateError('Kết nối đã đóng trong khi truyền tệp.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
        buffered = await channel.getBufferedAmount();
      }
    }
    if (isCancelled()) throw StateError('Truyền tệp đã bị hủy.');
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Kết nối đã đóng trong khi truyền tệp.');
    }
    await channel.send(RTCDataChannelMessage.fromBinary(packet));
  }

  void cancelFileTransfer(String transferId) {
    final outgoing = _outgoingTransfers[transferId];
    if (outgoing != null) {
      outgoing.cancelled = true;
      if (!outgoing.accepted.isCompleted) outgoing.accepted.complete(false);
      final link = _links[outgoing.peerId];
      if (link != null) _sendData(link, {'type': 'file-cancel', 'transferId': transferId});
      _updateFileTransfer(transferId, status: 'cancelled');
      return;
    }
    final incoming = _incomingTransfers.remove(transferId);
    if (incoming != null) {
      final link = _links[incoming.peerId];
      if (link != null) _sendData(link, {'type': 'file-cancel', 'transferId': transferId});
      _updateFileTransfer(transferId, status: 'cancelled');
    }
  }

  Future<void> _handleFileOffer(_PeerLink link, Map<String, dynamic> payload) async {
    final id = payload['transferId'] as String?;
    final rawName = payload['name'] as String?;
    final rawSize = payload['size'];
    final size = rawSize is int ? rawSize : -1;
    if (id == null || !FileTransferProtocol.isValidTransferId(id) ||
        rawName == null || rawName.length > 1024 || size < 0 || size > FileTransferProtocol.maxFileBytes ||
        _incomingTransfers.containsKey(id)) {
      _sendData(link, {'type': 'file-reject', 'transferId': id ?? ''});
      return;
    }
    // The receiver buffers the full file before saving. Serialize incoming
    // receive/save operations globally to keep peak mobile memory bounded.
    if (_incomingTransfers.isNotEmpty || _savingIncomingTransfers > 0) {
      _sendData(link, {'type': 'file-reject', 'transferId': id});
      return;
    }

    final safeName = FileTransferProtocol.sanitizeFileName(rawName);
    final peerName = _peerNames[link.id] ?? 'MTUNZ device';
    final incoming = _IncomingFileTransfer(
      id: id,
      peerId: link.id,
      peerName: peerName,
      fileName: safeName,
      size: size,
    );
    _incomingTransfers[id] = incoming;
    _recordFileTransfer(FileTransferView(
      id: id,
      peerId: link.id,
      peerName: peerName,
      fileName: safeName,
      size: size,
      transferred: 0,
      isOutgoing: false,
      status: 'waiting',
    ));

    var accepted = false;
    try {
      accepted = await onFileOffer(link.id, peerName, safeName, size);
    } catch (error) {
      if (!_disposed) onNotice('Không thể xác nhận yêu cầu nhận tệp: $error');
    }
    if (_disposed || !_incomingTransfers.containsKey(id)) return;
    if (!accepted) {
      _incomingTransfers.remove(id);
      _updateFileTransfer(id, status: 'rejected');
      _sendData(link, {'type': 'file-reject', 'transferId': id});
      return;
    }
    incoming.accepted = true;
    _updateFileTransfer(id, status: 'receiving');
    _sendData(link, {'type': 'file-accept', 'transferId': id});
  }

  void _handleFileChunk(_PeerLink link, Uint8List bytes) {
    final chunk = FileTransferProtocol.decodeChunk(bytes);
    if (chunk == null) {
      onNotice('Đã bỏ qua gói dữ liệu tệp không hợp lệ.');
      return;
    }
    final transfer = _incomingTransfers[chunk.transferId];
    if (transfer == null || transfer.peerId != link.id || !transfer.accepted) return;
    if (chunk.index != transfer.nextChunkIndex ||
        transfer.transferred + chunk.payload.length > transfer.size) {
      _abortIncomingFile(link, transfer, 'Dữ liệu tệp không đúng thứ tự hoặc vượt kích thước.');
      return;
    }
    transfer.builder.add(chunk.payload);
    transfer.transferred += chunk.payload.length;
    transfer.nextChunkIndex++;
    if (transfer.nextChunkIndex % 8 == 0 || transfer.transferred == transfer.size) {
      _updateFileTransfer(transfer.id, transferred: transfer.transferred);
    }
  }

  void _abortIncomingFile(_PeerLink link, _IncomingFileTransfer transfer, String reason) {
    _incomingTransfers.remove(transfer.id);
    _updateFileTransfer(transfer.id, status: 'failed');
    _sendData(link, {'type': 'file-cancel', 'transferId': transfer.id});
    if (!_disposed) onNotice(reason);
  }

  Future<void> _finishIncomingFile(_PeerLink link, String transferId) async {
    final transfer = _incomingTransfers[transferId];
    if (transfer == null || transfer.peerId != link.id) return;
    if (transfer.transferred != transfer.size) {
      _abortIncomingFile(link, transfer, 'Tệp nhận được chưa đầy đủ, vui lòng gửi lại.');
      return;
    }
    _updateFileTransfer(transferId, status: 'saving');
    final bytes = transfer.builder.takeBytes();
    _savingIncomingTransfers++;
    var saved = false;
    try {
      saved = await onFileReceived(transfer.peerName, transfer.fileName, bytes);
    } catch (error) {
      if (!_disposed) onNotice('Không lưu được tệp nhận: $error');
    } finally {
      _savingIncomingTransfers--;
      _incomingTransfers.remove(transferId);
    }
    _sendData(link, {'type': 'file-saved', 'transferId': transferId, 'saved': saved});
    _updateFileTransfer(transferId, status: saved ? 'completed' : 'not_saved');
  }

  void _recordFileTransfer(FileTransferView view) {
    _fileTransfers[view.id] = view;
    while (_fileTransfers.length > 20) {
      FileTransferView? removable;
      for (final item in _fileTransfers.values) {
        if (!item.canCancel) {
          removable = item;
          break;
        }
      }
      if (removable == null) break;
      _fileTransfers.remove(removable.id);
    }
    _publishFileTransfers();
  }

  void _updateFileTransfer(String id, {int? transferred, String? status}) {
    final current = _fileTransfers[id];
    if (current == null) return;
    _fileTransfers[id] = current.copyWith(transferred: transferred, status: status);
    _publishFileTransfers();
  }

  void _publishFileTransfers() {
    if (!_disposed) onFileTransfersChanged(_fileTransfers.values.toList(growable: false).reversed.toList(growable: false));
  }

  String _newTransferId() {
    final random = math.Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
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
        final link = await _ensureLink(from);
        if (link.connection.signalingState == RTCSignalingState.RTCSignalingStateStable) {
          await link.connection.restartIce();
          await _makeOffer(from, force: true);
        }
      }
      return;
    }
    if (type != 'offer' && type != 'answer' &&
        type != 'candidate' && type != 'candidate-batch') return;
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
    } else if (type == 'candidate') {
      await _addRemoteCandidate(link, data);
    } else {
      final candidates = data['candidates'];
      if (candidates is List) {
        for (final item in candidates) {
          if (item is Map<String, dynamic>) {
            await _addRemoteCandidate(link, item);
          }
        }
      }
    }
  }

  Future<void> _addRemoteCandidate(_PeerLink link, Map<String, dynamic> data) async {
    final candidate = data['candidate'] as String?;
    if (candidate == null || candidate.isEmpty) return;
    final rawIndex = data['sdpMLineIndex'];
    final ice = RTCIceCandidate(
      candidate,
      data['sdpMid'] as String?,
      rawIndex is num ? rawIndex.toInt() : null,
    );
    if (link.remoteDescriptionSet) {
      await link.connection.addCandidate(ice);
    } else {
      link.pendingCandidates.add(ice);
    }
  }

  void _queueLocalCandidate(_PeerLink link, Map<String, dynamic> candidate) {
    if (_disposed || _links[link.id] != link) return;
    link.pendingLocalCandidates.add(candidate);
    if (link.pendingLocalCandidates.length >= 8) {
      link.candidateBatchTimer?.cancel();
      link.candidateBatchTimer = null;
      unawaited(_flushLocalCandidates(link));
    } else {
      link.candidateBatchTimer ??= Timer(const Duration(milliseconds: 40), () {
        link.candidateBatchTimer = null;
        unawaited(_flushLocalCandidates(link));
      });
    }
  }

  Future<void> _flushLocalCandidates(_PeerLink link) async {
    if (_disposed || _links[link.id] != link || link.flushingCandidates ||
        link.pendingLocalCandidates.isEmpty) {
      return;
    }
    link.flushingCandidates = true;
    try {
      while (!_disposed && _links[link.id] == link && link.pendingLocalCandidates.isNotEmpty) {
        final count = math.min(8, link.pendingLocalCandidates.length);
        final batch = link.pendingLocalCandidates.take(count).toList(growable: false);
        link.pendingLocalCandidates.removeRange(0, count);
        try {
          await signaling.sendSignal(link.id, 'candidate-batch', {'candidates': batch});
        } catch (_) {
          link.pendingLocalCandidates.insertAll(0, batch);
          rethrow;
        }
      }
    } catch (error) {
      if (!_disposed) onNotice('Không gửi được nhóm ICE candidate: $error');
    } finally {
      link.flushingCandidates = false;
      if (!_disposed && _links[link.id] == link &&
          link.pendingLocalCandidates.isNotEmpty && link.candidateBatchTimer == null) {
        link.candidateBatchTimer = Timer(const Duration(milliseconds: 500), () {
          link.candidateBatchTimer = null;
          unawaited(_flushLocalCandidates(link));
        });
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
        'iceCandidatePoolSize': 4,
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun.cloudflare.com:3478'},
          ...iceServers,
        ],
      };
      connection = await createPeerConnection(configuration);
      if (_disposed) throw StateError('Phiên MTUNZ đã đóng.');

      final link = _PeerLink(id: peerId, connection: connection, renderer: renderer);
      _links[peerId] = link;
      connection.onIceCandidate = (candidate) {
        if (candidate.candidate == null || _disposed || _links[peerId] != link) return;
        _queueLocalCandidate(link, candidate.toMap());
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
        final stateText = state.toString().toLowerCase();
        final connected = stateText.endsWith('connected') && !stateText.contains('disconnected');
        final interrupted = stateText.contains('disconnected') || stateText.endsWith('failed');
        if (connected) {
          link.recoveryTimer?.cancel();
          link.recoveryTimer = null;
          link.recoveryAttempts = 0;
          link.recoveryNoticeShown = false;
          link.recoveryExhausted = false;
        } else if (interrupted && !link.recoveryExhausted) {
          if (!link.recoveryNoticeShown) {
            link.recoveryNoticeShown = true;
            onNotice('Kết nối thiết bị đang gián đoạn; MTUNZ sẽ tự thử khôi phục.');
          }
          _scheduleIceRecovery(link);
        }
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

  static const int _maxIceRecoveryAttempts = 3;

  void _scheduleIceRecovery(_PeerLink link) {
    if (_disposed || _links[link.id] != link || link.recoveryTimer != null ||
        link.recoveryAttempts >= _maxIceRecoveryAttempts || link.recoveryExhausted) {
      return;
    }
    final delay = switch (link.recoveryAttempts) {
      0 => const Duration(seconds: 2),
      1 => const Duration(seconds: 5),
      _ => const Duration(seconds: 10),
    };
    link.recoveryTimer = Timer(delay, () {
      link.recoveryTimer = null;
      unawaited(_attemptIceRecovery(link));
    });
  }

  Future<void> _attemptIceRecovery(_PeerLink link) async {
    if (_disposed || _links[link.id] != link || link.recoveryExhausted) return;
    link.recoveryAttempts++;
    try {
      // Only the lower peer ID creates offers, avoiding simultaneous offers.
      if (signaling.peerId.compareTo(link.id) > 0) {
        await signaling.sendSignal(link.id, 'renegotiate-request', const {});
      } else if (link.connection.signalingState == RTCSignalingState.RTCSignalingStateStable) {
        await link.connection.restartIce();
        await _makeOffer(link.id, force: true);
      }
    } catch (error) {
      if (!_disposed && _links[link.id] == link) {
        onNotice('Thử khôi phục kết nối chưa thành công: $error');
      }
    }
    if (_disposed || _links[link.id] != link) return;
    if (link.recoveryAttempts < _maxIceRecoveryAttempts) {
      _scheduleIceRecovery(link);
    } else {
      link.recoveryExhausted = true;
      onNotice('Chưa thể khôi phục kết nối. Hãy kiểm tra mạng hoặc thử ghép nối lại thiết bị.');
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
    channel.onDataChannelState = (_) {
      if (!_disposed && _links[link.id] == link) _notify();
    };
    channel.onMessage = (message) async {
      if (message.isBinary) {
        _handleFileChunk(link, message.binary);
        return;
      }
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
        } else if (type == 'file-offer') {
          await _handleFileOffer(link, payload);
        } else if (type == 'file-accept') {
          final id = payload['transferId'] as String?;
          final outgoing = id == null ? null : _outgoingTransfers[id];
          if (outgoing != null && outgoing.peerId == link.id && !outgoing.accepted.isCompleted) {
            outgoing.accepted.complete(true);
          }
        } else if (type == 'file-reject') {
          final id = payload['transferId'] as String?;
          final outgoing = id == null ? null : _outgoingTransfers[id];
          if (outgoing != null && outgoing.peerId == link.id) {
            outgoing.rejected = true;
            if (!outgoing.accepted.isCompleted) outgoing.accepted.complete(false);
            _updateFileTransfer(id!, status: 'rejected');
          }
        } else if (type == 'file-cancel') {
          final id = payload['transferId'] as String?;
          if (id != null) {
            final outgoing = _outgoingTransfers[id];
            if (outgoing != null && outgoing.peerId == link.id) {
              outgoing.cancelled = true;
              if (!outgoing.accepted.isCompleted) outgoing.accepted.complete(false);
            }
            final incoming = _incomingTransfers[id];
            if (incoming != null && incoming.peerId == link.id) {
              _incomingTransfers.remove(id);
              _updateFileTransfer(id, status: 'cancelled');
            }
          }
        } else if (type == 'file-complete') {
          final id = payload['transferId'] as String?;
          if (id != null) await _finishIncomingFile(link, id);
        } else if (type == 'file-saved') {
          final id = payload['transferId'] as String?;
          final outgoing = id == null ? null : _outgoingTransfers[id];
          if (id != null && (outgoing == null ? _fileTransfers[id]?.peerId == link.id : outgoing.peerId == link.id)) {
            _updateFileTransfer(id, status: payload['saved'] == true ? 'completed' : 'not_saved');
          }
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
    channel.send(RTCDataChannelMessage(jsonEncode(data))).catchError((Object error) {
      if (!_disposed) onNotice('Không gửi được thao tác tới thiết bị: $error');
    });
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
    for (final transfer in _outgoingTransfers.values.where((item) => item.peerId == peerId).toList()) {
      transfer.cancelled = true;
      if (!transfer.accepted.isCompleted) transfer.accepted.complete(false);
      _outgoingTransfers.remove(transfer.id);
      _updateFileTransfer(transfer.id, status: 'cancelled');
    }
    for (final transfer in _incomingTransfers.values.where((item) => item.peerId == peerId).toList()) {
      _incomingTransfers.remove(transfer.id);
      _updateFileTransfer(transfer.id, status: 'cancelled');
    }
    final link = _links.remove(peerId);
    _peerNames.remove(peerId);
    if (link == null) return;
    link.recoveryTimer?.cancel();
    link.candidateBatchTimer?.cancel();
    link.pendingLocalCandidates.clear();
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
    for (final transfer in _outgoingTransfers.values) {
      transfer.cancelled = true;
      if (!transfer.accepted.isCompleted) transfer.accepted.complete(false);
    }
    _outgoingTransfers.clear();
    _incomingTransfers.clear();
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

class _OutgoingFileTransfer {
  _OutgoingFileTransfer({required this.id, required this.peerId});
  final String id;
  final String peerId;
  final Completer<bool> accepted = Completer<bool>();
  bool cancelled = false;
  bool rejected = false;
}

class _IncomingFileTransfer {
  _IncomingFileTransfer({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.size,
  });
  final String id;
  final String peerId;
  final String peerName;
  final String fileName;
  final int size;
  final BytesBuilder builder = BytesBuilder(copy: false);
  int transferred = 0;
  int nextChunkIndex = 0;
  bool accepted = false;
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
  Timer? recoveryTimer;
  Timer? candidateBatchTimer;
  final List<Map<String, dynamic>> pendingLocalCandidates = [];
  bool flushingCandidates = false;
  int recoveryAttempts = 0;
  bool recoveryNoticeShown = false;
  bool recoveryExhausted = false;
  final List<RTCIceCandidate> pendingCandidates = [];
}
