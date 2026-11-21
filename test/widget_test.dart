import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show CircularProgressIndicator;
import 'package:walk_on_photos/depth/depth_estimator.dart';
import 'package:walk_on_photos/depth/depth_map.dart';
import 'package:walk_on_photos/main.dart';
import 'package:walk_on_photos/render/fly_camera.dart';
import 'package:walk_on_photos/render/scene_painter.dart';
import 'package:walk_on_photos/scene/image_utils.dart';
import 'package:walk_on_photos/scene/photo_scene.dart';
import 'package:walk_on_photos/scene/scene_builder.dart';
import 'package:walk_on_photos/ui/widgets.dart';

/// Synthetic photo: left half red, right half blue, with a green square
/// in the middle that is much closer than the "wall" behind it.
Future<ui.Image> _testPhoto(int w, int h) {
  final Uint8List rgba = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int i = (y * w + x) * 4;
      final bool inBox = _inBox(x / w, y / h);
      rgba[i] = inBox ? 0 : (x < w / 2 ? 220 : 20);
      rgba[i + 1] = inBox ? 220 : 20;
      rgba[i + 2] = inBox ? 0 : (x < w / 2 ? 20 : 220);
      rgba[i + 3] = 255;
    }
  }
  return rgbaToImage(rgba, w, h);
}

bool _inBox(double u, double v) => u > 0.35 && u < 0.65 && v > 0.3 && v < 0.7;

DepthMap _boxDepth(int w, int h) {
  final Float32List d = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      d[y * w + x] = _inBox(x / w, y / h) ? 5.0 : 1.0;
    }
  }
  return DepthMap(w, h, d);
}

Future<ui.Image> _render(PhotoScene scene, FlyCamera cam, Size size) async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
  ScenePainter(scene: scene, camera: cam).paint(canvas, size);
  final ui.Picture pic = rec.endRecording();
  return pic.toImage(size.width.toInt(), size.height.toInt());
}

Future<List<int>> _pixel(ui.Image img, int x, int y) async {
  final ByteData data = (await img.toByteData())!;
  final int i = (y * img.width + x) * 4;
  return <int>[data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
}

void main() {
  testWidgets('PhotoFlyInOverlay loads 3D model first then flies particles to 3D positions without spinner or text', (
    WidgetTester tester,
  ) async {
    PhotoScene? scene;
    ui.Image? img;
    await tester.runAsync(() async {
      img = await _testPhoto(120, 90);
      scene = await SceneBuilder.build(
        img!,
        _boxDepth(60, 45),
        options: const SceneBuildOptions(gridLongSide: 32),
      );
    });
    expect(scene!.introParticles, isNotNull);
    expect(scene!.introParticles!.count, greaterThan(0));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PhotoFlyInOverlay(scene: null, busy: true, version: 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Text), findsNothing);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PhotoFlyInOverlay(scene: scene, busy: false, version: 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(CustomPaint), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3000));
    await tester.pumpAndSettle();
    scene?.dispose();
    img?.dispose();
  });

  testWidgets('desktop UI asks for a photo on an empty background', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const WalkOnPhotosApp(forceDesktop: true));
    await tester.pump();
    expect(find.text('Walk on Photos'), findsOneWidget);
    expect(find.text('添加照片'), findsOneWidget);
  });

  test('FlyCamera: W walks forward (-Z), mouse drag turns', () {
    final FlyCamera cam = FlyCamera();
    cam.handleKey(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyW,
        logicalKey: LogicalKeyboardKey.keyW,
        timeStamp: Duration.zero,
      ),
    );
    cam.update(0.05);
    expect(cam.z, lessThan(0));
    expect(cam.x, closeTo(0, 1e-9));
    cam.releaseAllKeys();
    cam.look(-100, 0); // drag left -> turn left -> positive yaw
    expect(cam.yaw, greaterThan(0));
    cam.dispose();
  });

  test('model input is aspect-preserving and a multiple of 14', () {
    final ({int w, int h}) s = DepthEstimator.inputSizeFor(4032, 3024);
    expect(s.w, 518);
    expect(s.h % 14, 0);
    expect(s.w / s.h, closeTo(4 / 3, 0.05));
    final Float32List t = DepthEstimator.preprocess(
      Uint8List.fromList(<int>[255, 0, 0, 255]),
      1,
      1,
    );
    expect(t[0], closeTo((1 - 0.485) / 0.229, 1e-4));
  });

  test('push-pull fill replaces holes with surrounding colors', () {
    const int w = 16, h = 16;
    final Uint8List rgba = Uint8List(w * h * 4);
    final Uint8List hole = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      rgba[i * 4] = 200; // red background
      rgba[i * 4 + 3] = 255;
      final int x = i % w, y = i ~/ w;
      if (x > 5 && x < 10 && y > 5 && y < 10) {
        hole[i] = 1;
        rgba[i * 4 + 1] = 255; // green occluder to be erased
        rgba[i * 4] = 0;
      }
    }
    final Uint8List out = pushPullFill(rgba, hole, w, h);
    final int c = (8 * w + 8) * 4;
    expect(out[c], closeTo(200, 2));
    expect(out[c + 1], 0);
  });

  testWidgets('scene: foreground torn at depth edges, occluded regions filled '
      'by an inpainted background layer, start view reproduces photo, '
      'walking adds parallax', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final ui.Image photo = await _testPhoto(320, 240);
      final PhotoScene scene = await SceneBuilder.build(
        photo,
        _boxDepth(160, 120),
        options: const SceneBuildOptions(gridLongSide: 64),
      );

      // Torn: fewer foreground triangles than a full grid.
      const int gw = 64, gh = 48;
      expect(scene.foreground.triangleCount, lessThan((gw - 1) * (gh - 1) * 2));
      expect(scene.background, isNotNull);
      expect(scene.background!.alphas, isNotNull);

      // The box is nearer than the wall.
      double zAt(SceneLayer l, int gx, int gy) =>
          l.positions[(gy * gw + gx) * 3 + 2];
      expect(zAt(scene.foreground, 32, 24), greaterThan(zAt(scene.foreground, 2, 2)));

      // The background layer has geometry behind the box (farther than the
      // box) and fades out past the photo frame.
      final SceneLayer bgl = scene.background!;
      bool foundBehindBox = false;
      for (int i = 0; i < bgl.vertexCount; i++) {
        final double x = bgl.positions[i * 3], y = bgl.positions[i * 3 + 1];
        final double z = bgl.positions[i * 3 + 2];
        if (x.abs() < 0.3 && y.abs() < 0.3 &&
            z < zAt(scene.foreground, 32, 24) - 0.5) {
          foundBehindBox = true;
        }
      }
      expect(foundBehindBox, isTrue);
      expect(bgl.alphas!.reduce(math.min), lessThan(0.05));

      // Start pose: screen == photo (box center green, left wall red).
      const Size size = Size(320, 240);
      final FlyCamera cam = FlyCamera();
      ui.Image frame = await _render(scene, cam, size);
      expect((await _pixel(frame, 160, 120))[1], greaterThan(150));
      expect((await _pixel(frame, 30, 120))[0], greaterThan(150));

      // Step right: the near box shifts left much more than the far wall,
      // revealing the inpainted wall (not green) at center (160) while the
      // box sits shifted left around x = 32..75.
      cam.x = 0.6;
      frame = await _render(scene, cam, size);
      final List<int> c = await _pixel(frame, 160, 120);
      final List<int> shiftedBox = await _pixel(frame, 50, 120);
      expect(shiftedBox[1], greaterThan(150));
      expect(c[1], lessThan(100));

      // Walk into the scene past the box: no crash, near-plane clipping.
      cam
        ..x = 0
        ..z = -2.5;
      await _render(scene, cam, size);
      scene.dispose();
      photo.dispose();
    });
  });

  // End-to-end with REAL Depth Anything output (dumped from the ONNX model in
  // Python): renders the photo from several viewpoints into PNGs.
  // Run with: WOP_PHOTO=x.jpg WOP_DEPTH=x.depth WOP_OUT=dir flutter test
  final String? photoPath = Platform.environment['WOP_PHOTO'];
  testWidgets(
    'renders a real photo from new viewpoints',
    (WidgetTester tester) async {
      await tester.runAsync(() async {
        final Uint8List raw = File(Platform.environment['WOP_DEPTH']!).readAsBytesSync();
        final ByteData bd = ByteData.sublistView(raw);
        final int dw = bd.getInt32(0, Endian.little);
        final int dh = bd.getInt32(4, Endian.little);
        final Float32List vals = Float32List(dw * dh);
        for (int i = 0; i < vals.length; i++) {
          vals[i] = bd.getFloat32(8 + i * 4, Endian.little);
        }
        final ui.Image photo = await decodePhoto(File(photoPath!).readAsBytesSync());
        final PhotoScene scene = await SceneBuilder.build(photo, DepthMap(dw, dh, vals));
        final String out = Platform.environment['WOP_OUT']!;
        const Size size = Size(640, 480);
        final List<(String, double, double, double, double)> views =
            <(String, double, double, double, double)>[
              ('0_start', 0, 0, 0, 0),
              ('1_step_left', -0.5, 0, 0, 0),
              ('2_step_right_turn', 0.6, 0, -0.4, 0.25),
              ('3_walk_in', 0, -1.0, 0, 0),
              ('4_walk_in_look_left', 0.2, -1.6, 0, 0.6),
            ];
        for (final (String name, double x, double z, double y, double yaw) in views) {
          final FlyCamera cam = FlyCamera()
            ..x = x
            ..z = z
            ..y = y
            ..yaw = yaw;
          final ui.Image img = await _render(scene, cam, size);
          File('$out/$name.png').writeAsBytesSync(await encodePng(img));
        }
        // ignore: avoid_print
        print('fg tris ${scene.foreground.triangleCount}, '
            'bg tris ${scene.background?.triangleCount}, '
            'depth ${dw}x$dh, focal ${scene.focalPx.toStringAsFixed(0)}, '
            'max z ${scene.foreground.positions.reduce(math.min).toStringAsFixed(2)}');
        scene.dispose();
      });
    },
    skip: photoPath == null,
  );
}
