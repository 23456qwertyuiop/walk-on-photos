import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

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

/// Animates the chosen photo flying piece-by-piece into the frame while the
/// 3D scene is being reconstructed (no spinner or loading text).
class PhotoFlyInOverlay extends StatefulWidget {
  const PhotoFlyInOverlay({
    super.key,
    required this.image,
    required this.busy,
    required this.version,
  });

  final ui.Image? image;
  final bool busy;
  final int version;

  @override
  State<PhotoFlyInOverlay> createState() => _PhotoFlyInOverlayState();
}

class _PhotoFlyInOverlayState extends State<PhotoFlyInOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _flyCtrl;
  late final AnimationController _fadeCtrl;
  bool _active = false;
  ui.Image? _shownImage;

  @override
  void initState() {
    super.initState();
    _flyCtrl = AnimationController(vsync: this);
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 0.0,
    );
    _syncState();
  }

  @override
  void didUpdateWidget(covariant PhotoFlyInOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.version != oldWidget.version ||
        widget.busy != oldWidget.busy ||
        widget.image != oldWidget.image) {
      _syncState(oldBusy: oldWidget.busy, oldVersion: oldWidget.version);
    }
  }

  void _syncState({bool oldBusy = false, int oldVersion = -1}) {
    if (widget.busy) {
      if (widget.image != null &&
          (!_active || widget.version != oldVersion || !oldBusy)) {
        _active = true;
        _shownImage = widget.image;
        _fadeCtrl.value = 1.0;
        _flyCtrl.stop();
        _flyCtrl.value = 0.0;
        // Fly ~86% of tiles in over 1.35s, then drift slowly toward 96% if
        // model inference is still running on slower devices.
        _flyCtrl
            .animateTo(
              0.86,
              duration: const Duration(milliseconds: 1350),
              curve: Curves.easeOutQuad,
            )
            .then((_) {
              if (mounted && widget.busy) {
                _flyCtrl.animateTo(
                  0.96,
                  duration: const Duration(milliseconds: 3000),
                  curve: Curves.linear,
                );
              }
            });
      }
    } else if (_active) {
      // Scene finished building: snap remaining tiles into place, then dissolve
      // smoothly into the live 3D scene.
      _flyCtrl
          .animateTo(
            1.0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted || widget.busy) return;
            _fadeCtrl.reverse().then((_) {
              if (mounted && !widget.busy) {
                setState(() {
                  _active = false;
                  _shownImage = null;
                });
              }
            });
          });
    }
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? img = _shownImage ?? widget.image;
    if (!_active || img == null) return const SizedBox.shrink();

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_flyCtrl, _fadeCtrl]),
        builder: (BuildContext context, _) {
          if (_fadeCtrl.value <= 0.001) return const SizedBox.shrink();
          return CustomPaint(
            painter: _PhotoFlyInPainter(
              image: img,
              progress: _flyCtrl.value,
              masterOpacity: _fadeCtrl.value,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _PhotoFlyInPainter extends CustomPainter {
  _PhotoFlyInPainter({
    required this.image,
    required this.progress,
    required this.masterOpacity,
  });

  final ui.Image image;
  final double progress;
  final double masterOpacity;

  static double _hash01(int a, int b, int c) {
    int h = a * 374761393 + b * 668265263 + c * 2147483647;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= (h >> 16);
    return (h & 0x00FFFFFF) / 16777216.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || masterOpacity <= 0.0) return;

    final double iw = image.width.toDouble();
    final double ih = image.height.toDouble();
    // Cover-fit rectangle matching ScenePainter's starting camera projection.
    final double cover = math.max(size.width / iw, size.height / ih);
    final double dstW = iw * cover;
    final double dstH = ih * cover;
    final double ox = (size.width - dstW) * 0.5;
    final double oy = (size.height - dstH) * 0.5;
    final double screenCx = size.width * 0.5;
    final double screenCy = size.height * 0.5;

    final bool landscape = iw >= ih;
    const int longTiles = 18;
    final int cols = landscape
        ? longTiles
        : math.max(8, (longTiles * iw / ih).round());
    final int rows = landscape
        ? math.max(8, (longTiles * ih / iw).round())
        : longTiles;

    final double srcTileW = iw / cols;
    final double srcTileH = ih / rows;
    final double dstTileW = dstW / cols;
    final double dstTileH = dstH / rows;

    final Paint tilePaint = Paint()..filterQuality = FilterQuality.medium;

    const double tileDur = 0.30;
    const double maxStart = 1.0 - tileDur;

    for (int r = 0; r < rows; r++) {
      final double nv = (r + 0.5) / rows - 0.5;
      for (int c = 0; c < cols; c++) {
        final double nu = (c + 0.5) / cols - 0.5;
        final double radial = math.sqrt(nu * nu + nv * nv) / 0.7071;
        final double h0 = _hash01(c, r, 1);
        final double h1 = _hash01(c, r, 2);
        final double h2 = _hash01(c, r, 3);
        final double h3 = _hash01(c, r, 4);

        final double startT =
            (radial * 0.42 + h0 * 0.58).clamp(0.0, 1.0) * maxStart;
        final double localT = ((progress - startT) / tileDur).clamp(0.0, 1.0);
        if (localT <= 0.001) continue;

        final double eased = Curves.easeOutCubic.transform(localT);
        final double alpha =
            ((localT / 0.35).clamp(0.0, 1.0) * masterOpacity).clamp(0.0, 1.0);

        // Slight overlap (+0.6px) prevents hairline seams between settled tiles.
        final Rect src = Rect.fromLTWH(
          c * srcTileW,
          r * srcTileH,
          srcTileW,
          srcTileH,
        );
        final double targetLeft = ox + c * dstTileW;
        final double targetTop = oy + r * dstTileH;
        final double targetCx = targetLeft + dstTileW * 0.5;
        final double targetCy = targetTop + dstTileH * 0.5;

        tilePaint.color = Color.fromRGBO(255, 255, 255, alpha);

        if (eased >= 0.999) {
          final Rect dst = Rect.fromLTWH(
            targetLeft - 0.5,
            targetTop - 0.5,
            dstTileW + 1.0,
            dstTileH + 1.0,
          );
          canvas.drawImageRect(image, src, dst, tilePaint);
        } else {
          final double inv = 1.0 - eased;
          final double dx =
              (targetCx - screenCx) * (0.9 + h1 * 0.9) * inv +
              (h2 - 0.5) * 140.0 * inv;
          final double dy =
              (targetCy - screenCy) * (0.9 + h2 * 0.9) * inv +
              (h3 - 0.5) * 140.0 * inv;
          final double scale = 0.25 + 0.75 * eased;
          final double angle = (h1 - 0.5) * 0.55 * inv;

          canvas.save();
          canvas.translate(targetCx + dx, targetCy + dy);
          canvas.rotate(angle);
          canvas.scale(scale);
          final Rect localDst = Rect.fromCenter(
            center: Offset.zero,
            width: dstTileW + 1.0,
            height: dstTileH + 1.0,
          );
          canvas.drawImageRect(image, src, localDst, tilePaint);
          canvas.restore();
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PhotoFlyInPainter old) =>
      old.image != image ||
      old.progress != progress ||
      old.masterOpacity != masterOpacity;
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
