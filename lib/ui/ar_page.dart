import 'package:material_ui/material_ui.dart';

import '../ar/ar_bridge.dart';
import 'scene_loader.dart';
import 'widgets.dart';

/// Phone with ARKit / ARCore: live camera background, the photo anchored in
/// your room, and you physically walk into it.
class ArPage extends StatefulWidget {
  const ArPage({super.key, required this.loader});

  final SceneLoader loader;

  @override
  State<ArPage> createState() => _ArPageState();
}

class _ArPageState extends State<ArPage> with WidgetsBindingObserver {
  ArViewController? _ar;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ArViewController? ar = _ar;
    if (ar == null) return;
    if (state == AppLifecycleState.paused) ar.pause();
    if (state == AppLifecycleState.resumed) ar.resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ar?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final SceneLoader loader = widget.loader;
    if (await loader.pickAndBuild()) {
      await _ar?.loadScene(loader.scene!);
    }
  }

  void _onCreated(ArViewController c) {
    setState(() => _ar = c);
    final scene = widget.loader.scene;
    if (scene != null) c.loadScene(scene);
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ArView(onCreated: _onCreated),
        ListenableBuilder(
          listenable: widget.loader,
          builder: (BuildContext context, _) {
            final SceneLoader loader = widget.loader;
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (loader.scene == null && !loader.busy)
                  AddPhotoCard(
                    subtitle:
                        '选一张照片，AI 重建成 3D 空间并放在你所在的位置。\n'
                        '然后拿着手机真的往前走，就能走进照片里。',
                    error: loader.error,
                    onPick: _pick,
                  ),
                if (loader.scene != null)
                  Positioned(
                    top: pad.top + 12,
                    left: 12,
                    right: 12,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        GlassButton(
                          icon: Icons.add_photo_alternate_rounded,
                          label: '换一张照片',
                          onTap: _pick,
                        ),
                        GlassButton(
                          icon: Icons.place_rounded,
                          label: '放到我这里',
                          onTap: () => _ar?.placeHere(),
                        ),
                      ],
                    ),
                  ),
                if (_ar != null && !loader.busy)
                  Positioned(
                    bottom: pad.bottom + 24,
                    left: 16,
                    right: 16,
                    child: Center(child: _status(loader)),
                  ),
                PhotoFlyInOverlay(
                  image: loader.previewPhoto,
                  busy: loader.busy,
                  version: loader.sceneVersion,
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _status(SceneLoader loader) {
    final ArViewController ar = _ar!;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        ar.tracking,
        ar.trackingHint,
        ar.placed,
      ]),
      builder: (BuildContext context, _) {
        final String text = switch (ar.tracking.value) {
          ArTracking.normal when loader.scene == null => '空间识别完成，添加一张照片吧',
          ArTracking.normal when ar.placed.value =>
            '照片已放在你面前 —— 往前走，走进去看看；转身、蹲下都可以',
          ArTracking.normal => '正在放置场景…',
          ArTracking.limited => _limitedHint(ar.trackingHint.value),
          ArTracking.unavailable => 'AR 追踪不可用',
          ArTracking.error => 'AR 出错：${ar.trackingHint.value ?? ''}',
          ArTracking.initializing => '缓慢左右移动手机，识别周围环境…',
        };
        return HintBubble(text);
      },
    );
  }

  String _limitedHint(String? reason) => switch (reason) {
    'excessiveMotion' => '移动太快了，请放慢',
    'insufficientFeatures' => '画面缺少细节，对准有纹理的地方',
    'insufficientLight' => '光线太暗',
    'relocalizing' => '正在重新定位…',
    _ => '缓慢左右移动手机，识别周围环境…',
  };
}
