import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// First-person camera used by the Flutter renderer.
///
/// Desktop: WASD / arrows to walk, Q/E (or Shift/Space) down/up, mouse drag
/// to look. Mobile fallback (no ARKit/ARCore): gyroscope + gravity to look,
/// on-screen joystick to walk.
///
/// World: the photo was taken from the origin looking down -Z, +Y up, meters.
class FlyCamera extends ChangeNotifier {
  FlyCamera({this.useSensors = false});

  final bool useSensors;

  double x = 0, y = 0, z = 0;

  /// Positive yaw turns left; positive pitch looks up.
  double yaw = 0, pitch = 0;

  /// Walking speed in m/s (hold R to run).
  double walkSpeed = 1.4;

  static const double maxPitch = 1.35;

  /// Smoothed velocity (m/s): walking eases in and out instead of starting
  /// and stopping instantly like a camera on rails.
  double _vx = 0, _vy = 0, _vz = 0;

  /// Vertical head bob while walking (meters), added to [eyeY].
  double bob = 0;
  double _bobPhase = 0;

  /// Height of the eye used for rendering (position + head bob).
  double get eyeY => y + bob;

  final Set<LogicalKeyboardKey> _keys = <LogicalKeyboardKey>{};
  double _joyX = 0, _joyY = 0;

  bool gyroEnabled = true;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _lastGyro;
  double? _gravityPitch;

  // ---------------------------------------------------------------- input

  /// Returns true if the key was consumed.
  bool handleKey(KeyEvent e) {
    final LogicalKeyboardKey k = e.logicalKey;
    if (!_movementKeys.contains(k)) return false;
    if (e is KeyDownEvent) _keys.add(k);
    if (e is KeyUpEvent) _keys.remove(k);
    return true;
  }

  void releaseAllKeys() => _keys.clear();

  void look(double dxPixels, double dyPixels, {double sensitivity = 0.0045}) {
    yaw -= dxPixels * sensitivity;
    pitch = (pitch - dyPixels * sensitivity).clamp(-maxPitch, maxPitch);
    notifyListeners();
  }

  void setJoystick(double x, double y) {
    _joyX = x.clamp(-1.0, 1.0);
    _joyY = y.clamp(-1.0, 1.0);
  }

  void moveForward(double meters) {
    x -= math.sin(yaw) * meters;
    z -= math.cos(yaw) * meters;
    _clamp();
    notifyListeners();
  }

  void reset() {
    x = 0;
    y = 0;
    z = 0;
    yaw = 0;
    pitch = useSensors && gyroEnabled ? (_gravityPitch ?? 0) : 0;
    _vx = _vy = _vz = 0;
    bob = 0;
    _bobPhase = 0;
    notifyListeners();
  }

  // ---------------------------------------------------------------- update

  static final Set<LogicalKeyboardKey> _movementKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyR,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  bool _down(LogicalKeyboardKey a, [LogicalKeyboardKey? b]) =>
      _keys.contains(a) || (b != null && _keys.contains(b));

  void update(double dt) {
    if (dt <= 0 || dt > 0.1) return;
    double fwd = _joyY, side = _joyX, up = 0;
    if (_down(LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp)) fwd += 1;
    if (_down(LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown)) fwd -= 1;
    if (_down(LogicalKeyboardKey.keyD, LogicalKeyboardKey.arrowRight)) {
      side += 1;
    }
    if (_down(LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft)) {
      side -= 1;
    }
    if (_down(LogicalKeyboardKey.keyE, LogicalKeyboardKey.space)) up += 1;
    if (_down(LogicalKeyboardKey.keyQ, LogicalKeyboardKey.shiftLeft) ||
        _down(LogicalKeyboardKey.shiftRight)) {
      up -= 1;
    }
    final bool input = fwd != 0 || side != 0 || up != 0;
    final double moving = _vx.abs() + _vy.abs() + _vz.abs();
    if (!input && moving < 1e-3 && bob.abs() < 1e-4) {
      if (moving != 0 || bob != 0) {
        _vx = _vy = _vz = 0;
        bob = 0;
        notifyListeners();
      }
      return;
    }

    final double len = math.sqrt(fwd * fwd + side * side);
    if (len > 1) {
      fwd /= len;
      side /= len;
    }
    final double speed =
        walkSpeed * (_down(LogicalKeyboardKey.keyR) ? 2.5 : 1.0);
    final double s = math.sin(yaw), c = math.cos(yaw);
    // forward = (-sin, 0, -cos), right = (cos, 0, -sin)
    final double tx = (-s * fwd + c * side) * speed;
    final double tz = (-c * fwd - s * side) * speed;
    final double ty = up * speed * 0.7;
    // Ease toward the target velocity (~0.25 s to full speed / to a stop).
    final double k = 1 - math.exp(-dt * (input ? 9.0 : 7.0));
    _vx += (tx - _vx) * k;
    _vy += (ty - _vy) * k;
    _vz += (tz - _vz) * k;
    x += _vx * dt;
    y += _vy * dt;
    z += _vz * dt;

    // Gentle head bob: ~2 steps per second at walking pace, a couple of cm.
    final double hs = math.sqrt(_vx * _vx + _vz * _vz);
    _bobPhase += dt * hs * 8.0;
    bob = math.sin(_bobPhase) * 0.016 * math.min(1.0, hs / walkSpeed);
    _clamp();
    notifyListeners();
  }

  void _clamp() {
    x = x.clamp(-8.0, 8.0);
    y = y.clamp(-1.6, 2.5);
    z = z.clamp(-12.0, 4.0);
  }

  // --------------------------------------------------------------- sensors

  void startSensors() {
    if (!useSensors || kIsWeb) return;
    try {
      _gyroSub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(_onGyro, onError: (_) {}, cancelOnError: true);
      _accelSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(_onAccel, onError: (_) {}, cancelOnError: true);
    } catch (_) {
      // No sensors: joystick + drag still work.
    }
  }

  void setGyroEnabled(bool v) {
    gyroEnabled = v;
    _lastGyro = null;
    notifyListeners();
  }

  void _onAccel(AccelerometerEvent e) {
    // Portrait axes: y to the top of the screen, z out of the screen.
    // Upright phone -> pitch 0; top tilted toward the user (rear camera
    // looking up) -> z < 0 -> positive pitch.
    final double g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (g < 4) return;
    _gravityPitch = math.atan2(-e.z, e.y).clamp(-maxPitch, maxPitch);
  }

  void _onGyro(GyroscopeEvent e) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastGyro;
    _lastGyro = now;
    if (!gyroEnabled || last == null) return;
    final double dt = now.difference(last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.25) return;
    // Rotation about the device's up axis (y) turns the view; positive =
    // counter-clockwise seen from above = turning left = positive yaw.
    yaw += e.y * dt;
    double p = pitch + e.x * dt;
    final double? gp = _gravityPitch;
    if (gp != null) p = p * 0.97 + gp * 0.03; // drift-free horizon
    pitch = p.clamp(-maxPitch, maxPitch);
    notifyListeners();
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }
}
