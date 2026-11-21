import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../render/fly_camera.dart';
import '../render/scene_painter.dart';
import 'scene_loader.dart';
import 'widgets.dart';

/// Fallback for phones without ARKit/ARCore: camera background, gyroscope
/// to look around, joystick to walk.
class GyroPage extends StatefulWidget {
  const GyroPage({super.key, required this.loader});

  final SceneLoader loader;

  @override
  State<GyroPage> createState() => _GyroPageState();
}

class _GyroPageState extends State<GyroPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final FlyCamera _camera = FlyCamera(useSensors: true);
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  CameraController? _cam;
  bool _starting = false;
  String? _camError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _camera.startSensors();
    _ticker = createTicker((Duration t) {
      final double dt = (t - _last).inMicroseconds / 1e6;
      _last = t;
      _camera.update(dt);
    })..start();
    _startCamera();
  }

  Future<void> _startCamera() async {
    if (_starting || _cam != null) return;
    _starting = true;
    try {
      final List<CameraDescription> cams = await availableCameras();
      if (cams.isEmpty) throw StateError('没有摄像头');
      final CameraController c = CameraController(
        cams.firstWhere(
          (CameraDescription d) => d.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first,
        ),
        ResolutionPreset.high,
        enableAudio: false,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _cam = c);
    } catch (e) {
      if (mounted) setState(() => _camError = '$e');
    } finally {
      _starting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final CameraController? c = _cam;
      if (c == null) return;
      setState(() => _cam = null);
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _camera.dispose();
    _cam?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (await widget.loader.pickAndBuild()) _camera.reset();
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final CameraController? cam = _cam;
    return ListenableBuilder(
      listenable: widget.loader,
      builder: (BuildContext context, _) {
        final SceneLoader loader = widget.loader;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (DragUpdateDetails d) =>
              _camera.look(d.delta.dx, 0, sensitivity: 0.006),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (cam != null && cam.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: cam.value.previewSize?.height ?? 1080,
                    height: cam.value.previewSize?.width ?? 1920,
                    child: CameraPreview(cam),
                  ),
                )
              else
                ColoredBox(
                  color: Colors.black,
                  child: _camError == null
                      ? null
                      : Center(child: HintBubble('摄像头不可用：$_camError')),
                ),
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
                      '选一张照片，AI 重建成 3D 空间。\n'
                      '转动手机环顾四周，用左下角摇杆走进去。\n'
                      '（此手机不支持 ARKit/ARCore，无法用真实走动）',
                  error: loader.error,
                  onPick: _pick,
                ),
              if (loader.scene != null && !loader.busy) ...<Widget>[
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
                        icon: Icons.my_location_rounded,
                        label: '回到拍摄点',
                        onTap: _camera.reset,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 20,
                  bottom: pad.bottom + 24,
                  child: Joystick(onChanged: _camera.setJoystick),
                ),
                Positioned(
                  right: 16,
                  bottom: pad.bottom + 24,
                  child: const HintBubble('转动手机看四周\n摇杆走动'),
                ),
              ],
              PhotoFlyInOverlay(
                image: loader.previewPhoto,
                busy: loader.busy,
                version: loader.sceneVersion,
              ),
            ],
          ),
        );
      },
    );
  }
}
