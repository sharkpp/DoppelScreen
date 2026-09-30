import 'package:flutter/foundation.dart';

import 'generated/host_api.g.dart';

/// コアから届いた最新の状態を持つ。UI はこれだけを見て描く。
///
/// 状態の正はネイティブのコア側にあり、ここは写しでしかない。操作は `control` 経由で
/// コアへ送り、結果は `stateChanged` で戻ってくる（楽観的に書き換えない）。
class HostModel extends ChangeNotifier implements HostUIEvents {
  HostModel({HostUIControl? control}) : control = control ?? HostUIControl() {
    HostUIEvents.setUp(this);
    // 購読を始める前の変化を取りこぼさないよう、登録してから取りに行く
    this.control.currentState().then(_apply);
  }

  final HostUIControl control;

  HostState? _state;
  HostState? get state => _state;

  @override
  void stateChanged(HostState state) => _apply(state);

  void _apply(HostState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    HostUIEvents.setUp(null);
    super.dispose();
  }
}

extension HostStateQueries on HostState {
  /// 承認待ちのビューア（SPEC.md §5.2）。最優先で見せる
  int get approvalRequests =>
      streams.where((stream) => stream.status == StreamStatus.awaitingApproval).length;

  int get activeStreams => streams.where((stream) => stream.isActive).length;

  bool get hasEndpoints => streams.any((stream) => stream.endpoints.isNotEmpty);
}

extension DisplayStreamStateQueries on DisplayStreamState {
  bool get isActive => switch (status) {
        StreamStatus.awaitingApproval || StreamStatus.starting || StreamStatus.streaming => true,
        StreamStatus.idle || StreamStatus.failed => false,
      };
}
