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

class BusyOverlay extends StatelessWidget {
  const BusyOverlay(this.stage, {super.key});

  final String stage;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(color: kAccent),
            const SizedBox(height: 14),
            Text(stage, style: const TextStyle(color: Colors.white)),
          ],
        ),
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
