import 'package:flutter/material.dart';

import 'host_model.dart';
import 'views/host_view.dart';

/// ホストの操作画面（SPEC.md §2.3 HostUI、docs/adr/0002-host-ui-flutter.md）。
///
/// ネイティブのアプリに埋め込まれて動く。エンジンはウィンドウを閉じても残るため、
/// `main` はプロセスの寿命で 1 回しか走らない。
void main() {
  // `HostModel` はコアとのチャネルを張る。チャネルはバインディングを先に要る
  WidgetsFlutterBinding.ensureInitialized();
  runApp(HostApp(model: HostModel()));
}

class HostApp extends StatelessWidget {
  const HostApp({super.key, required this.model});

  final HostModel model;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: model,
        builder: (context, _) => HostView(model: model),
      ),
    );
  }

  /// デスクトップの道具として控えめに。色は状態（承認待ち・配信中・エラー）にだけ使う
  static ThemeData _theme(Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3A6EA5),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.neutral,
      ),
      visualDensity: VisualDensity.compact,
      // 待機中に動くものを置かない。ホスト UI のウィンドウが配信中の画面の上にあると、
      // その描画も符号化される（docs/adr/0002-host-ui-flutter.md）
      splashFactory: NoSplash.splashFactory,
    );
  }
}
