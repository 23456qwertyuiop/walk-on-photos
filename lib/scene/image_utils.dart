import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Size that fits [w]x[h] into [longSide] while keeping the aspect ratio.
/// Never upscales.
({int w, int h}) fitLongSide(int w, int h, int longSide) {
  final double s = math.min(1.0, longSide / math.max(w, h));
  return (w: math.max(1, (w * s).round()), h: math.max(1, (h * s).round()));
}

/// Draws [image] scaled to exactly [w]x[h].
Future<ui.Image> scaleImage(ui.Image image, int w, int h) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image out = await picture.toImage(w, h);
  picture.dispose();
  return out;
}

/// Downscales [image] so its long side is at most [longSide].
Future<ui.Image> resizeImage(ui.Image image, int longSide) {
  final ({int w, int h}) s = fitLongSide(image.width, image.height, longSide);
  return scaleImage(image, s.w, s.h);
}

/// Raw RGBA bytes of [image] scaled to [w]x[h].
Future<Uint8List> imageToRgba(ui.Image image, int w, int h) async {
  final ui.Image scaled = await scaleImage(image, w, h);
  final ByteData? data = await scaled.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  scaled.dispose();
  if (data == null) throw StateError('无法读取图像像素');
  return data.buffer.asUint8List();
}

Future<ui.Image> rgbaToImage(Uint8List rgba, int w, int h) {
  final Completer<ui.Image> c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<Uint8List> encodePng(ui.Image image) async {
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('无法编码 PNG');
  return data.buffer.asUint8List();
}

/// Decodes an encoded image (JPEG/PNG/HEIC where supported), applying a
/// long-side cap to keep memory sane for 48 MP phone photos.
///
/// Uses [ui.instantiateImageCodecWithSize], which works on every platform
/// including the web (ImageDescriptor's size getters do not).
Future<ui.Image> decodePhoto(Uint8List bytes, {int maxLongSide = 3072}) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes,
  );
  final ui.Codec codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (int w, int h) {
      final ({int w, int h}) s = fitLongSide(w, h, maxLongSide);
      return ui.TargetImageSize(width: s.w, height: s.h);
    },
  );
  final ui.FrameInfo frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}
