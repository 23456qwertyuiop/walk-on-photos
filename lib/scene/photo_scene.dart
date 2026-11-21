import 'dart:typed_data';
import 'dart:ui' as ui;

/// One textured triangle mesh of the reconstructed scene.
///
/// Coordinates are in meters. The original photo camera sits at the origin,
/// looks down -Z, +Y is up. Texture coordinates are normalized with the
/// origin at the top-left of the texture.
class SceneLayer {
  SceneLayer({
    required this.positions,
    required this.uvs,
    required this.indices,
    required this.texture,
    required this.texturePng,
  });

  /// xyz per vertex.
  final Float32List positions;

  /// uv per vertex, normalized [0, 1], v pointing down.
  final Float32List uvs;

  /// 3 indices per triangle.
  final Int32List indices;

  /// Decoded texture for the Flutter (software) renderer.
  final ui.Image texture;

  /// PNG-encoded texture for the native AR renderers.
  final Uint8List texturePng;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  void dispose() => texture.dispose();
}

/// A photo reconstructed as a walkable 3D space.
///
/// [foreground] is the photo itself, unprojected with the estimated depth and
/// torn apart at depth discontinuities (so a person does not get "rubber
/// sheeted" onto the wall behind them). [background] fills the gaps that open
/// up behind torn edges once you move, using depth and colors propagated from
/// the surrounding background (a simple form of layered-depth inpainting).
class PhotoScene {
  PhotoScene({
    required this.foreground,
    required this.background,
    required this.imageWidth,
    required this.imageHeight,
    required this.focalPx,
  });

  final SceneLayer foreground;
  final SceneLayer? background;

  /// Size of the source photo in pixels.
  final int imageWidth;
  final int imageHeight;

  /// Focal length (in source-photo pixels) used to unproject the photo.
  final double focalPx;

  List<SceneLayer> get layers => <SceneLayer>[
    ?background,
    foreground,
  ];

  void dispose() {
    foreground.dispose();
    background?.dispose();
  }
}
