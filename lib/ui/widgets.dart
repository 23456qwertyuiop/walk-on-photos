import 'package:material_ui/material_ui.dart';

import '../render/fly_camera.dart';
import '../render/scene_painter.dart';
import '../scene/photo_scene.dart';

const Color kAccent = Color(0xFF7FE7D9);

/// Small translucent pill button for the HUD.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        canRequestFocus: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: kAccent),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hint text on a translucent background.
class HintBubble extends StatelessWidget {
  const HintBubble(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }
}

/// First-run card asking for a photo.
class AddPhotoCard extends StatelessWidget {
  const AddPhotoCard({
    super.key,
    required this.subtitle,
    required this.onPick,
    this.error,
  });

  final String subtitle;
  final VoidCallback onPick;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.view_in_ar_rounded, size: 48, color: kAccent),
            const SizedBox(height: 12),
            const Text(
              'Walk on Photos',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add_photo_alternate_rounded),
              label: const Text('添加照片'),
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Black-screen fade -> build 3D model first -> ~3s 3D reveal where particles
/// fly in 3D space straight to their exact 3D model positions ahead of the
/// viewer, then glide forward into the interactive 3D scene.
class PhotoFlyInOverlay extends StatefulWidget {
  const PhotoFlyInOverlay({
    super.key,
    required this.scene,
    required this.busy,
    required this.version,
    this.hasError = false,
  });

  final PhotoScene? scene;
  final bool busy;
  final int version;
  final bool hasError;

  @override
  State<PhotoFlyInOverlay> createState() => _PhotoFlyInOverlayState();
}

class _PhotoFlyInOverlayState extends State<PhotoFlyInOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _blackCtrl;
  late final AnimationController _revealCtrl;
  late final AnimationController _glideCtrl;
  final FlyCamera _introCam = FlyCamera();

  bool _active = false;
  bool _revealing = false;
  int _activeVersion = -1;
  PhotoScene? _revealScene;

  @override
  void initState() {
    super.initState();
    _blackCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _revealCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _glideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _syncState();
  }

  @override
  void didUpdateWidget(covariant PhotoFlyInOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.version != oldWidget.version ||
        widget.busy != oldWidget.busy ||
        widget.scene != oldWidget.scene ||
        widget.hasError != oldWidget.hasError) {
      _syncState();
    }
  }

  void _syncState() {
    if (widget.busy && (!_active || widget.version != _activeVersion)) {
      _active = true;
      _revealing = false;
      _activeVersion = widget.version;
      _revealScene = null;
      _revealCtrl.stop();
      _revealCtrl.value = 0.0;
      _glideCtrl.stop();
      _glideCtrl.value = 0.0;

      // 1. First black out the screen ("先黑场") while the 3D model loads.
      _blackCtrl.forward(from: 0.0).then((_) {
        if (mounted && _active && !widget.busy && !_revealing) {
          _begin3DReveal();
        }
      });
      return;
    }

    if (_active && !widget.busy && !_revealing) {
      if (widget.hasError || widget.scene == null) {
        _abortToIdle();
      } else if (!_blackCtrl.isAnimating) {
        _begin3DReveal();
      }
    }
  }

  void _begin3DReveal() {
    if (!mounted || !_active || _revealing || widget.busy) return;
    final PhotoScene? s = widget.scene;
    if (widget.hasError || s == null) {
      _abortToIdle();
      return;
    }

    _revealing = true;
    _revealScene = s;

    // 2. Once the 3D model is built, fly particles directly into their exact
    // 3D coordinates over ~3s while the 3D model fades in ahead of you.
    final int startedVersion = _activeVersion;
    _revealCtrl.forward(from: 0.0).then((_) {
      if (!mounted || !_active || _activeVersion != startedVersion) return;
      // 3. Glide smoothly forward from ahead (+1.65m) to the start viewpoint.
      _glideCtrl.forward(from: 0.0).then((_) {
        if (mounted && !widget.busy && _activeVersion == startedVersion) {
          setState(() {
            _active = false;
            _revealing = false;
            _revealScene = null;
          });
        }
      });
    });
  }

  void _abortToIdle() {
    if (!mounted || !_active) return;
    final int startedVersion = _activeVersion;
    _blackCtrl.reverse().then((_) {
      if (mounted && !widget.busy && _activeVersion == startedVersion) {
        setState(() {
          _active = false;
          _revealing = false;
          _revealScene = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _blackCtrl.dispose();
    _revealCtrl.dispose();
    _glideCtrl.dispose();
    _introCam.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          _blackCtrl,
          _revealCtrl,
          _glideCtrl,
        ]),
        builder: (BuildContext context, _) {
          final double glideT = Curves.easeInOutCubic.transform(_glideCtrl.value);
          final double blackAlpha =
              (_blackCtrl.value * (1.0 - glideT)).clamp(0.0, 1.0);
          if (blackAlpha <= 0.001 && glideT >= 0.999) {
            return const SizedBox.shrink();
          }
          final PhotoScene? scene = _revealScene;
          final double zPullback = 1.65 * (1.0 - glideT);
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(
                color: Color.fromRGBO(0, 0, 0, blackAlpha),
              ),
              if (scene != null && _revealCtrl.value > 0.001)
                CustomPaint(
                  painter: ScenePainter(
                    scene: scene,
                    camera: _introCam,
                    reveal: _revealCtrl.value,
                    zPullback: zPullback,
                  ),
                  size: Size.infinite,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Thumbstick for walking on phones without AR tracking.
class Joystick extends StatefulWidget {
  const Joystick({super.key, required this.onChanged, this.size = 120});

  final void Function(double x, double y) onChanged;
  final double size;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero;

  void _update(Offset local) {
    final double r = widget.size / 2;
    final double max = r * 0.62;
    Offset d = local - Offset(r, r);
    if (d.distance > max) d = Offset.fromDirection(d.direction, max);
    setState(() => _knob = d);
    widget.onChanged(d.dx / max, -d.dy / max);
  }

  void _reset() {
    setState(() => _knob = Offset.zero);
    widget.onChanged(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (DragStartDetails d) => _update(d.localPosition),
      onPanUpdate: (DragUpdateDetails d) => _update(d.localPosition),
      onPanEnd: (_) => _reset(),
      onPanCancel: _reset,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.3),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        alignment: Alignment.center,
        child: Transform.translate(
          offset: _knob,
          child: Container(
            width: widget.size * 0.4,
            height: widget.size * 0.4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}
