import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../scene/photo_scene.dart';

const String kArViewType = 'walk_on_photos/ar_view';
const MethodChannel _arChannel = MethodChannel('walk_on_photos/ar');

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// Whether this device can do 6-DoF world tracking (ARKit / ARCore).
Future<bool> isArSupported() async {
  if (!_isMobilePlatform) return false;
  try {
    return await _arChannel.invokeMethod<bool>('isSupported') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

Future<bool> requestCameraPermission() async {
  if (!_isMobilePlatform) return false;
  try {
    return await _arChannel.invokeMethod<bool>('requestCameraPermission') ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Tracking quality reported by the native AR session.
enum ArTracking { initializing, normal, limited, unavailable, error }

/// Talks to one native AR view.
///
/// The scene is anchored in the real world at the phone's pose when it is
/// placed: the photo's original camera = where you are standing, facing the
/// way you are facing. Physically walking forward walks you into the photo.
class ArViewController {
  ArViewController._(int id)
    : _channel = MethodChannel('walk_on_photos/ar_view_$id') {
    _channel.setMethodCallHandler(_onNative);
  }

  final MethodChannel _channel;
  final ValueNotifier<ArTracking> tracking = ValueNotifier<ArTracking>(
    ArTracking.initializing,
  );
  final ValueNotifier<String?> trackingHint = ValueNotifier<String?>(null);
  final ValueNotifier<bool> placed = ValueNotifier<bool>(false);

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'onTracking':
        final String s = call.arguments as String? ?? '';
        final List<String> parts = s.split(':');
        tracking.value = switch (parts.first) {
          'normal' => ArTracking.normal,
          'limited' => ArTracking.limited,
          'notAvailable' => ArTracking.unavailable,
          'error' => ArTracking.error,
          _ => ArTracking.initializing,
        };
        trackingHint.value = parts.length > 1
            ? parts.sublist(1).join(':')
            : null;
      case 'onPlaced':
        placed.value = true;
    }
    return null;
  }

  /// Uploads the scene. It is placed at the current phone pose as soon as
  /// tracking is good.
  Future<void> loadScene(PhotoScene scene) async {
    placed.value = false;
    final ParticleCloud? particles = scene.particles;
    await _channel.invokeMethod<void>('loadScene', <String, Object>{
      'layers': <Map<String, Object>>[
        for (final SceneLayer l in scene.layers)
          <String, Object>{
            'positions': l.positions,
            'uvs': l.uvs,
            'indices': l.indices,
            'texture': l.texturePng,
          },
      ],
      if (particles != null && particles.count > 0)
        'particles': <String, Object>{
          'positions': particles.positions,
          'colors': particles.colors,
          'sizes': particles.sizes,
        },
    });
  }

  /// Re-anchors the scene at the phone's current pose.
  Future<void> placeHere() async {
    placed.value = false;
    await _channel.invokeMethod<void>('placeHere');
  }

  Future<void> pause() => _channel.invokeMethod<void>('pause');
  Future<void> resume() => _channel.invokeMethod<void>('resume');

  void dispose() {
    _channel.setMethodCallHandler(null);
    tracking.dispose();
    trackingHint.dispose();
    placed.dispose();
  }
}

/// Native AR camera view (camera feed + anchored 3D photo).
class ArView extends StatelessWidget {
  const ArView({super.key, required this.onCreated});

  final ValueChanged<ArViewController> onCreated;

  @override
  Widget build(BuildContext context) {
    void created(int id) => onCreated(ArViewController._(id));

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: kArViewType,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: created,
      );
    }
    // Hybrid composition: required for a GLSurfaceView camera feed.
    return PlatformViewLink(
      viewType: kArViewType,
      surfaceFactory: (BuildContext context, PlatformViewController c) {
        return AndroidViewSurface(
          controller: c as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        return PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: kArViewType,
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener(created)
          ..create();
      },
    );
  }
}
