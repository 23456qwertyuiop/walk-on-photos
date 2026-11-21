import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/animation.dart' show Curves;
import 'package:flutter/rendering.dart';

import '../scene/photo_scene.dart';
import 'fly_camera.dart';

/// Renders a [PhotoScene] with a true pinhole projection on the Flutter
/// canvas: per-frame view transform, near-plane clipping (so geometry does
/// not pop out when you walk into it) and back-to-front depth sorting.
///
/// When [reveal] < 1.0, particles from [PhotoScene.introParticles] fly through
/// 3D space directly to their exact 3D model positions while the reconstructed
/// 3D model fades in ahead of the camera (pulled back by [zPullback]).
class ScenePainter extends CustomPainter {
  ScenePainter({
    required this.scene,
    required this.camera,
    this.reveal = 1.0,
    this.zPullback = 0.0,
  }) : super(repaint: camera);

  final PhotoScene scene;
  final FlyCamera camera;
  final double reveal;
  final double zPullback;

  static const double nearPlane = 0.05;

  /// Scratch buffers keyed weakly by layer/cloud/scene, so they die with it.
  static final Expando<_LayerBuffers> _buffers = Expando<_LayerBuffers>();
  static final Expando<_ParticleBuffers> _particleBuffers =
      Expando<_ParticleBuffers>();
  static final Expando<_IntroBuffers> _introBuffers = Expando<_IntroBuffers>();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double cover = math.max(
      size.width / scene.imageWidth,
      size.height / scene.imageHeight,
    );

    final double sy = math.sin(camera.yaw);
    final double cyw = math.cos(camera.yaw);
    final _View view = _View(
      x: camera.x + sy * zPullback,
      y: camera.y,
      z: camera.z + cyw * zPullback,
      yaw: camera.yaw,
      pitch: camera.pitch,
      focal: scene.focalPx * cover,
      cx: size.width / 2,
      cy: size.height / 2,
      width: size.width,
      height: size.height,
    );

    final double rev = reveal.clamp(0.0, 1.0);
    final double meshOpacity = rev >= 0.999
        ? 1.0
        : Curves.easeInOutCubic.transform(((rev - 0.24) / 0.72).clamp(0.0, 1.0));

    // Draw characteristic-colored occluded background particles first, then
    // the sharp foreground mesh on top.
    if (meshOpacity > 0.005) {
      final ParticleCloud? particles = scene.particles;
      if (particles != null && particles.count > 0) {
        _drawParticles(canvas, particles, view, alphaScale: meshOpacity);
      }
      for (final SceneLayer layer in scene.layers) {
        _drawLayer(canvas, layer, view, opacity: meshOpacity);
      }
    }

    // While revealing (< 1.0), fly 3D surface particles from outer 3D space
    // straight into their exact 3D model positions.
    if (rev < 0.999) {
      final ParticleCloud? intro = scene.introParticles;
      if (intro != null && intro.count > 0) {
        _drawIntroParticles(canvas, intro, view, rev, meshOpacity);
      }
    }
  }

  void _drawParticles(
    Canvas canvas,
    ParticleCloud cloud,
    _View v, {
    double alphaScale = 1.0,
  }) {
    final _ParticleBuffers b =
        _particleBuffers[cloud] ??= _ParticleBuffers(cloud);
    final int n = cloud.count;
    final Float32List p = cloud.positions;
    final Float32List sizes = cloud.sizes;

    final double sy = math.sin(v.yaw), cyw = math.cos(v.yaw);
    final double sp = math.sin(v.pitch), cp = math.cos(v.pitch);
    final double ox = v.x, oy = v.y, oz = v.z;

    int vis = 0;
    for (int i = 0; i < n; i++) {
      final double dx = p[i * 3] - ox;
      final double dy = p[i * 3 + 1] - oy;
      final double dz = p[i * 3 + 2] - oz;
      final double rx = dx * cyw - dz * sy;
      final double fw = -dx * sy - dz * cyw;
      final double ry = dy * cp - fw * sp;
      final double cz = dy * sp + fw * cp;
      if (cz < nearPlane) continue;

      final double inv = v.focal / cz;
      final double sx = v.cx + rx * inv;
      final double syy = v.cy - ry * inv;
      final double sr = (sizes[i] * inv).clamp(1.0, 3.2);

      if (sx + sr < 0 ||
          sx - sr > v.width ||
          syy + sr < 0 ||
          syy - sr > v.height) {
        continue;
      }

      int col = b.argb[i];
      if (alphaScale < 0.999) {
        final int a = (((col >>> 24) & 0xFF) * alphaScale).round().clamp(0, 255);
        col = (a << 24) | (col & 0x00FFFFFF);
      }

      b.sX[vis] = sx;
      b.sY[vis] = syy;
      b.sR[vis] = sr;
      b.sCol[vis] = col;
      b.key[vis] = cz;
      vis++;
    }
    if (vis == 0) return;

    _sortAndEmitHexParticles(canvas, b, vis);
  }

  void _drawIntroParticles(
    Canvas canvas,
    ParticleCloud cloud,
    _View v,
    double rev,
    double meshOpacity,
  ) {
    final _IntroBuffers ib = _introBuffers[cloud] ??= _IntroBuffers(cloud);
    final _ParticleBuffers b = ib.drawBuffers;
    final int n = cloud.count;
    final Float32List targetPos = cloud.positions;

    final double sy = math.sin(v.yaw), cyw = math.cos(v.yaw);
    final double sp = math.sin(v.pitch), cp = math.cos(v.pitch);
    final double ox = v.x, oy = v.y, oz = v.z;

    const double flightDur = 0.42;
    const double uniformPxRadius = 1.45;
    final double landedAlphaScale = (1.0 - meshOpacity * 0.92).clamp(0.0, 1.0);

    int vis = 0;
    for (int i = 0; i < n; i++) {
      final double t0 = ib.launchT[i];
      if (rev < t0) continue;

      final double rawFlight = ((rev - t0) / flightDur).clamp(0.0, 1.0);
      final double tx = targetPos[i * 3];
      final double ty = targetPos[i * 3 + 1];
      final double tz = targetPos[i * 3 + 2];

      double wx;
      double wy;
      double wz;
      int alpha;

      if (rawFlight < 0.999) {
        final double eased = Curves.easeOutCubic.transform(rawFlight);
        final double inv = 1.0 - eased;
        final double inv2 = inv * inv;
        final double mid2 = 2.0 * inv * eased;
        final double e2 = eased * eased;

        wx = inv2 * ib.startX[i] + mid2 * ib.ctrlX[i] + e2 * tx;
        wy = inv2 * ib.startY[i] + mid2 * ib.ctrlY[i] + e2 * ty;
        wz = inv2 * ib.startZ[i] + mid2 * ib.ctrlZ[i] + e2 * tz;
        alpha = 242;
      } else {
        wx = tx;
        wy = ty;
        wz = tz;
        alpha = (238.0 * landedAlphaScale).round().clamp(0, 255);
        if (alpha <= 2) continue;
      }

      final double dx = wx - ox;
      final double dy = wy - oy;
      final double dz = wz - oz;
      final double rx = dx * cyw - dz * sy;
      final double fw = -dx * sy - dz * cyw;
      final double ry = dy * cp - fw * sp;
      final double cz = dy * sp + fw * cp;
      if (cz < nearPlane) continue;

      final double inv = v.focal / cz;
      final double sx = v.cx + rx * inv;
      final double syy = v.cy - ry * inv;

      if (sx + uniformPxRadius < 0 ||
          sx - uniformPxRadius > v.width ||
          syy + uniformPxRadius < 0 ||
          syy - uniformPxRadius > v.height) {
        continue;
      }

      b.sX[vis] = sx;
      b.sY[vis] = syy;
      b.sR[vis] = uniformPxRadius;
      b.sCol[vis] = (alpha << 24) | (b.argb[i] & 0x00FFFFFF);
      b.key[vis] = cz;
      vis++;
    }
    if (vis == 0) return;

    _sortAndEmitHexParticles(canvas, b, vis);
  }

  void _sortAndEmitHexParticles(Canvas canvas, _ParticleBuffers b, int vis) {
    // Counting sort far -> near on log depth.
    const int buckets = 2048;
    const double logNear = -3.0;
    const double logFar = 3.4;
    final Int32List counts = b.counts..fillRange(0, buckets + 1, 0);
    final Int32List bucketOf = b.bucketOf;
    for (int i = 0; i < vis; i++) {
      final double lz = math.log(math.max(b.key[i], 1e-4));
      int k = ((logFar - lz) / (logFar - logNear) * (buckets - 1)).floor();
      k = k.clamp(0, buckets - 1);
      bucketOf[i] = k;
      counts[k + 1]++;
    }
    for (int k = 0; k < buckets; k++) {
      counts[k + 1] += counts[k];
    }
    for (int i = 0; i < vis; i++) {
      final int dst = counts[bucketOf[i]]++;
      b.oX[dst] = b.sX[i];
      b.oY[dst] = b.sY[i];
      b.oR[dst] = b.sR[i];
      b.oCol[dst] = b.sCol[i];
    }

    // Emit each particle as a crisp solid 4-triangle hexagon fan (from v0) in
    // a single drawVertices call.
    const List<double> cosH = <double>[
      1.0,
      0.5,
      -0.5,
      -1.0,
      -0.5,
      0.5,
    ];
    const List<double> sinH = <double>[
      0.0,
      0.8660254,
      0.8660254,
      0.0,
      -0.8660254,
      -0.8660254,
    ];

    final Float32List vPos = b.vPos;
    final Int32List vCol = b.vCol;
    int pPtr = 0;
    int cPtr = 0;
    for (int i = 0; i < vis; i++) {
      final double cx = b.oX[i];
      final double cy = b.oY[i];
      final double r = b.oR[i];
      final int col = b.oCol[i];

      final double x0 = cx + r * cosH[0];
      final double y0 = cy + r * sinH[0];
      for (int s = 1; s <= 4; s++) {
        vPos[pPtr++] = x0;
        vPos[pPtr++] = y0;
        vPos[pPtr++] = cx + r * cosH[s];
        vPos[pPtr++] = cy + r * sinH[s];
        vPos[pPtr++] = cx + r * cosH[s + 1];
        vPos[pPtr++] = cy + r * sinH[s + 1];

        vCol[cPtr++] = col;
        vCol[cPtr++] = col;
        vCol[cPtr++] = col;
      }
    }

    final int vertCount = vis * 12;
    final ui.Vertices vertices = ui.Vertices.raw(
      VertexMode.triangles,
      Float32List.sublistView(vPos, 0, vertCount * 2),
      colors: Int32List.sublistView(vCol, 0, vertCount),
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, b.paint);
    vertices.dispose();
  }

  void _drawLayer(
    Canvas canvas,
    SceneLayer layer,
    _View v, {
    double opacity = 1.0,
  }) {
    final _LayerBuffers b = _buffers[layer] ??= _LayerBuffers(layer);
    final int n = layer.vertexCount;
    final Float32List p = layer.positions;

    // 1. World -> camera space.
    final double sy = math.sin(v.yaw), cyw = math.cos(v.yaw);
    final double sp = math.sin(v.pitch), cp = math.cos(v.pitch);
    final double ox = v.x, oy = v.y, oz = v.z;
    for (int i = 0; i < n; i++) {
      final double dx = p[i * 3] - ox;
      final double dy = p[i * 3 + 1] - oy;
      final double dz = p[i * 3 + 2] - oz;
      final double rx = dx * cyw - dz * sy;
      final double fw = -dx * sy - dz * cyw;
      b.cx[i] = rx;
      b.cy[i] = dy * cp - fw * sp;
      b.cz[i] = dy * sp + fw * cp;
    }

    // 2. Clip against the near plane, project, cull, collect triangles.
    final Int32List idx = layer.indices;
    final Float32List uv = layer.uvs;
    final double tw = layer.texture.width.toDouble();
    final double th = layer.texture.height.toDouble();
    int out = 0; // output triangle count

    final Float32List polyX = b.polyX, polyY = b.polyY, polyZ = b.polyZ;
    final Float32List polyU = b.polyU, polyV = b.polyV;

    void emitPolygon(int count) {
      // Project polygon vertices.
      double minX = double.infinity, maxX = -double.infinity;
      double minY = double.infinity, maxY = -double.infinity;
      double zsum = 0;
      for (int k = 0; k < count; k++) {
        final double inv = v.focal / polyZ[k];
        final double sx = v.cx + polyX[k] * inv;
        final double syy = v.cy - polyY[k] * inv;
        polyX[k] = sx;
        polyY[k] = syy;
        if (sx < minX) minX = sx;
        if (sx > maxX) maxX = sx;
        if (syy < minY) minY = syy;
        if (syy > maxY) maxY = syy;
        zsum += polyZ[k];
      }
      if (maxX < 0 || minX > v.width || maxY < 0 || minY > v.height) return;
      final double depth = zsum / count;
      for (int k = 1; k + 1 < count; k++) {
        b.ensureCapacity(out + 1);
        final int o = out * 6;
        b.sPos[o] = polyX[0];
        b.sPos[o + 1] = polyY[0];
        b.sPos[o + 2] = polyX[k];
        b.sPos[o + 3] = polyY[k];
        b.sPos[o + 4] = polyX[k + 1];
        b.sPos[o + 5] = polyY[k + 1];
        b.sTex[o] = polyU[0] * tw;
        b.sTex[o + 1] = polyV[0] * th;
        b.sTex[o + 2] = polyU[k] * tw;
        b.sTex[o + 3] = polyV[k] * th;
        b.sTex[o + 4] = polyU[k + 1] * tw;
        b.sTex[o + 5] = polyV[k + 1] * th;
        b.key[out] = depth;
        out++;
      }
    }

    for (int t = 0; t < idx.length; t += 3) {
      final int a = idx[t], c = idx[t + 1], d = idx[t + 2];
      final bool ia = b.cz[a] >= nearPlane;
      final bool ic = b.cz[c] >= nearPlane;
      final bool id = b.cz[d] >= nearPlane;
      if (!ia && !ic && !id) continue;

      if (ia && ic && id) {
        for (int k = 0; k < 3; k++) {
          final int vi = k == 0 ? a : (k == 1 ? c : d);
          polyX[k] = b.cx[vi];
          polyY[k] = b.cy[vi];
          polyZ[k] = b.cz[vi];
          polyU[k] = uv[vi * 2];
          polyV[k] = uv[vi * 2 + 1];
        }
        emitPolygon(3);
        continue;
      }

      // Sutherland–Hodgman against z = near.
      int count = 0;
      for (int e = 0; e < 3; e++) {
        final int i0 = e == 0 ? a : (e == 1 ? c : d);
        final int i1 = e == 0 ? c : (e == 1 ? d : a);
        final double z0 = b.cz[i0], z1 = b.cz[i1];
        final bool in0 = z0 >= nearPlane, in1 = z1 >= nearPlane;
        if (in0) {
          polyX[count] = b.cx[i0];
          polyY[count] = b.cy[i0];
          polyZ[count] = z0;
          polyU[count] = uv[i0 * 2];
          polyV[count] = uv[i0 * 2 + 1];
          count++;
        }
        if (in0 != in1) {
          final double s = (nearPlane - z0) / (z1 - z0);
          polyX[count] = b.cx[i0] + (b.cx[i1] - b.cx[i0]) * s;
          polyY[count] = b.cy[i0] + (b.cy[i1] - b.cy[i0]) * s;
          polyZ[count] = nearPlane;
          polyU[count] = uv[i0 * 2] + (uv[i1 * 2] - uv[i0 * 2]) * s;
          polyV[count] =
              uv[i0 * 2 + 1] + (uv[i1 * 2 + 1] - uv[i0 * 2 + 1]) * s;
          count++;
        }
      }
      if (count >= 3) emitPolygon(count);
    }
    if (out == 0) return;

    // 3. Counting sort far -> near on log depth.
    const int buckets = 2048;
    const double logNear = -3.0; // ln(0.05)
    const double logFar = 3.4; // ln(30)
    final Int32List counts = b.counts..fillRange(0, buckets + 1, 0);
    final Int32List bucketOf = b.bucketOf;
    for (int i = 0; i < out; i++) {
      final double lz = math.log(math.max(b.key[i], 1e-4));
      int k = ((logFar - lz) / (logFar - logNear) * (buckets - 1)).floor();
      k = k.clamp(0, buckets - 1);
      bucketOf[i] = k;
      counts[k + 1]++;
    }
    for (int k = 0; k < buckets; k++) {
      counts[k + 1] += counts[k];
    }
    for (int i = 0; i < out; i++) {
      final int dst = counts[bucketOf[i]]++;
      final int s = i * 6, o = dst * 6;
      for (int j = 0; j < 6; j++) {
        b.oPos[o + j] = b.sPos[s + j];
        b.oTex[o + j] = b.sTex[s + j];
      }
    }

    b.paint.colorFilter = opacity >= 0.999
        ? null
        : ui.ColorFilter.mode(
            Color.fromRGBO(255, 255, 255, opacity),
            BlendMode.modulate,
          );

    final ui.Vertices vertices = ui.Vertices.raw(
      VertexMode.triangles,
      Float32List.sublistView(b.oPos, 0, out * 6),
      textureCoordinates: Float32List.sublistView(b.oTex, 0, out * 6),
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, b.paint);
    vertices.dispose();
  }

  @override
  bool shouldRepaint(covariant ScenePainter old) =>
      old.scene != scene ||
      old.camera != camera ||
      old.reveal != reveal ||
      old.zPullback != zPullback;
}

class _View {
  _View({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
    required this.pitch,
    required this.focal,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });

  final double x, y, z, yaw, pitch, focal, cx, cy, width, height;
}

/// Precomputed 3D Bezier start/control points and launch timings for flying
/// particles into their exact 3D model positions.
class _IntroBuffers {
  _IntroBuffers(ParticleCloud cloud)
    : drawBuffers = _ParticleBuffers(cloud),
      startX = Float32List(cloud.count),
      startY = Float32List(cloud.count),
      startZ = Float32List(cloud.count),
      ctrlX = Float32List(cloud.count),
      ctrlY = Float32List(cloud.count),
      ctrlZ = Float32List(cloud.count),
      launchT = Float32List(cloud.count) {
    final int n = cloud.count;
    final Float32List tp = cloud.positions;
    for (int i = 0; i < n; i++) {
      final double tx = tp[i * 3];
      final double ty = tp[i * 3 + 1];
      final double tz = tp[i * 3 + 2];

      final double h0 = _hash01(i, 11);
      final double h1 = _hash01(i, 23);
      final double h2 = _hash01(i, 37);
      final double h3 = _hash01(i, 53);
      final double h4 = _hash01(i, 71);

      final double baseAngle = math.atan2(ty, tx);
      final double angle = baseAngle + (h0 - 0.5) * 1.5;
      final double outerR = 2.2 + h1 * 2.8;
      final double sx = math.cos(angle) * outerR;
      final double sy = math.sin(angle) * outerR;
      // Fly in from both near-side peripheral space and deep outer space.
      final double sz = h2 < 0.5 ? (0.4 + h3 * 1.2) : (tz - 1.5 - h3 * 2.5);

      startX[i] = sx;
      startY[i] = sy;
      startZ[i] = sz;

      final double swirl = h4 > 0.5 ? 1.0 : -1.0;
      final double midAngle = angle + swirl * (0.35 + h0 * 0.45);
      final double midR = outerR * 0.52;
      ctrlX[i] = math.cos(midAngle) * midR;
      ctrlY[i] = math.sin(midAngle) * midR;
      ctrlZ[i] = (sz + tz) * 0.5 + (h2 - 0.5) * 0.6;

      // Launch waves staggered across [0.0, 0.58] (nearer objects slightly earlier).
      final double depthNorm = ((-tz - 1.2) / 7.8).clamp(0.0, 1.0);
      launchT[i] = (depthNorm * 0.24 + h4 * 0.34).clamp(0.0, 0.58);
    }
  }

  static double _hash01(int a, int b) {
    int h = a * 374761393 + b * 668265263;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= (h >> 16);
    return (h & 0x00FFFFFF) / 16777216.0;
  }

  final _ParticleBuffers drawBuffers;
  final Float32List startX, startY, startZ;
  final Float32List ctrlX, ctrlY, ctrlZ;
  final Float32List launchT;
}

/// Per-particle-cloud scratch buffers, reused across frames.
class _ParticleBuffers {
  _ParticleBuffers(ParticleCloud cloud)
    : argb = Int32List(cloud.count),
      sX = Float32List(cloud.count),
      sY = Float32List(cloud.count),
      sR = Float32List(cloud.count),
      sCol = Int32List(cloud.count),
      oX = Float32List(cloud.count),
      oY = Float32List(cloud.count),
      oR = Float32List(cloud.count),
      oCol = Int32List(cloud.count),
      key = Float32List(cloud.count),
      bucketOf = Int32List(cloud.count),
      vPos = Float32List(cloud.count * 24),
      vCol = Int32List(cloud.count * 12) {
    final Uint8List rgba = cloud.colors;
    for (int i = 0; i < cloud.count; i++) {
      final int o = i * 4;
      argb[i] =
          (rgba[o + 3] << 24) |
          (rgba[o] << 16) |
          (rgba[o + 1] << 8) |
          rgba[o + 2];
    }
  }

  final Int32List argb;
  final Float32List sX, sY, sR, oX, oY, oR, key;
  final Int32List sCol, oCol, bucketOf;
  final Int32List counts = Int32List(2049);
  final Float32List vPos;
  final Int32List vCol;
  final Paint paint = Paint()..isAntiAlias = false;
}

/// Per-layer scratch buffers, reused across frames.
class _LayerBuffers {
  _LayerBuffers(SceneLayer layer)
    : cx = Float32List(layer.vertexCount),
      cy = Float32List(layer.vertexCount),
      cz = Float32List(layer.vertexCount),
      paint = Paint()
        ..shader = ui.ImageShader(
          layer.texture,
          TileMode.clamp,
          TileMode.clamp,
          Float64List.fromList(<double>[
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1, //
          ]),
        )
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = false {
    ensureCapacity(layer.triangleCount + 64);
  }

  final Float32List cx, cy, cz;
  final Paint paint;

  final Float32List polyX = Float32List(8);
  final Float32List polyY = Float32List(8);
  final Float32List polyZ = Float32List(8);
  final Float32List polyU = Float32List(8);
  final Float32List polyV = Float32List(8);

  Float32List sPos = Float32List(0), sTex = Float32List(0);
  Float32List oPos = Float32List(0), oTex = Float32List(0);
  Float32List key = Float32List(0);
  Int32List bucketOf = Int32List(0);
  final Int32List counts = Int32List(2049);

  void ensureCapacity(int tris) {
    if (key.length >= tris) return;
    final int cap = math.max(tris, key.length * 2);
    Float32List grow(Float32List old, int len) =>
        Float32List(len)..setRange(0, old.length, old);
    sPos = grow(sPos, cap * 6);
    sTex = grow(sTex, cap * 6);
    oPos = Float32List(cap * 6);
    oTex = Float32List(cap * 6);
    key = grow(key, cap);
    bucketOf = Int32List(cap);
  }
}
