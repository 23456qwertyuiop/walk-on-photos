import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../render/fly_camera.dart';
import '../render/scene_painter.dart';
import 'scene_loader.dart';
import 'widgets.dart';

/// Computer: empty background, WASD to walk, mouse to look.
class DesktopPage extends StatefulWidget {
  const DesktopPage({super.key, required this.loader});

  final SceneLoader loader;

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage>
    with SingleTickerProviderStateMixin {
  final FlyCamera _camera = FlyCamera();
  final FocusNode _focus = FocusNode(debugLabel: 'scene');
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration t) {
      final double dt = (t - _last).inMicroseconds / 1e6;
      _last = t;
      _camera.update(dt);
    })..start();
    _focus.addListener(() {
      if (!_focus.hasFocus) _camera.releaseAllKeys();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _camera.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (await widget.loader.pickAndBuild()) _camera.reset();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final SceneLoader loader = widget.loader;
    return ListenableBuilder(
      listenable: loader,
      builder: (BuildContext context, _) {
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (FocusNode _, KeyEvent e) {
            if (e.logicalKey == LogicalKeyboardKey.keyF && e is KeyDownEvent) {
              _camera.reset();
              return KeyEventResult.handled;
            }
            return _camera.handleKey(e)
                ? KeyEventResult.handled
                : KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: _dragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab,
            child: Listener(
              onPointerDown: (_) {
                _focus.requestFocus();
                setState(() => _dragging = true);
              },
              onPointerUp: (_) => setState(() => _dragging = false),
              onPointerCancel: (_) => setState(() => _dragging = false),
              onPointerMove: (PointerMoveEvent e) {
                if (e.buttons != 0) _camera.look(e.delta.dx, e.delta.dy);
              },
              onPointerSignal: (PointerSignalEvent e) {
                if (e is PointerScrollEvent) {
                  _camera.moveForward(-e.scrollDelta.dy * 0.004);
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // Empty background.
                  const ColoredBox(color: Color(0xFF06070A)),
                  if (loader.scene != null)
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: ScenePainter(
                          scene: loader.scene!,
                          camera: _camera,
                        ),
                      ),
                    ),
                  if (loader.scene == null && !loader.busy)
                    AddPhotoCard(
                      subtitle:
                          '选一张照片，AI 估算真实深度并重建成 3D 空间。\n'
                          'WASD 走动，按住鼠标拖动环顾四周。',
                      error: loader.error,
                      onPick: _pick,
                    ),
                  if (loader.scene != null && !loader.busy) ..._hud(context),
                  PhotoFlyInOverlay(
                    image: loader.previewPhoto,
                    busy: loader.busy,
                    version: loader.sceneVersion,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _hud(BuildContext context) {
    return <Widget>[
      Positioned(
        top: 14,
        left: 14,
        child: Wrap(
          spacing: 8,
          children: <Widget>[
            GlassButton(
              icon: Icons.add_photo_alternate_rounded,
              label: '换一张照片',
              onTap: _pick,
            ),
            GlassButton(
              icon: Icons.my_location_rounded,
              label: '回到拍摄点 (F)',
              onTap: () {
                _camera.reset();
                _focus.requestFocus();
              },
            ),
          ],
        ),
      ),
      const Positioned(
        bottom: 16,
        left: 0,
        right: 0,
        child: Center(
          child: HintBubble(
            'W/S 前后 · A/D 左右 · 按住鼠标拖动 看四周 · Q/E 下降/上升 · 按住 R 奔跑 · 滚轮 前进后退',
          ),
        ),
      ),
    ];
  }
}
