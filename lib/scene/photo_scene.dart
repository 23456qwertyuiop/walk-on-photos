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

/// Colored 3D particles used to fill occluded / torn regions behind
/// foreground edges instead of blurry inpainted polygons.
class ParticleCloud {
  ParticleCloud({
    required this.positions,
    required this.colors,
    required this.sizes,
  }) : assert(positions.length == sizes.length * 3),
       assert(colors.length == sizes.length * 4);

  /// xyz per particle, in meters (same coordinate space as [SceneLayer]).
  final Float32List positions;

  /// RGBA uint8 per particle, 4 bytes per particle.
  final Uint8List colors;

  /// World-space radius in meters per particle.
  final Float32List sizes;

  int get count => sizes.length;
}

/// A photo reconstructed as a walkable 3D space.
///
/// [foreground] is the photo itself, unprojected with the estimated depth and
/// torn apart at depth discontinuities (so a person does not get "rubber
/// sheeted" onto the wall behind them). [particles] fills the occluded and
/// blurry torn-edge regions that open up once you move, using small 3D
/// particles carrying characteristic colors sampled from the surrounding scene.
class PhotoScene {
  PhotoScene({
    required this.foreground,
    required this.particles,
    this.introParticles,
    required this.imageWidth,
    required this.imageHeight,
    required this.focalPx,
  });

  final SceneLayer foreground;
  final ParticleCloud? particles;

  /// Dense 3D surface particles sampled across the reconstructed 3D model,
  /// used when particles fly into their exact 3D coordinates on entry.
  final ParticleCloud? introParticles;

  /// Size of the source photo in pixels.
  final int imageWidth;
  final int imageHeight;

  /// Focal length (in source-photo pixels) used to unproject the photo.
  final double focalPx;

  List<SceneLayer> get layers => <SceneLayer>[foreground];

  void dispose() {
    foreground.dispose();
  }
}
