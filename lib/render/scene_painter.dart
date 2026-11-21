import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../scene/photo_scene.dart';
import 'fly_camera.dart';

/// Renders a [PhotoScene] with a true pinhole projection on the Flutter
/// canvas: per-frame view transform, near-plane clipping (so geometry does
/// not pop out when you walk into it) and back-to-front depth sorting.
///
/// At the start pose the projection exactly reproduces the original photo
/// (cover-fit to the screen); every movement from there produces real
/// parallax from the estimated depth.
class ScenePainter extends CustomPainter {
  ScenePainter({required this.scene, required this.camera})
    : super(repaint: camera);

  final PhotoScene scene;
  final FlyCamera camera;

  static const double nearPlane = 0.05;

  /// Scratch buffers keyed weakly by layer, so they die with the scene.
  static final Expando<_LayerBuffers> _buffers = Expando<_LayerBuffers>();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double cover = math.max(
      size.width / scene.imageWidth,
      size.height / scene.imageHeight,
    );
    final _View view = _View(
      camera: camera,
      focal: scene.focalPx * cover,
      cx: size.width / 2,
      cy: size.height / 2,
      width: size.width,
      height: size.height,
    );
    // Background (inpainted) layer first: it only exists behind torn
    // foreground edges, so the foreground always wins where both overlap.
    for (final SceneLayer layer in scene.layers) {
      _drawLayer(canvas, layer, view);
    }
  }

  void _drawLayer(Canvas canvas, SceneLayer layer, _View v) {
    final _LayerBuffers b = _buffers[layer] ??= _LayerBuffers(layer);
    final int n = layer.vertexCount;
    final Float32List p = layer.positions;

    // 1. World -> camera space.
    final double sy = math.sin(v.camera.yaw), cyw = math.cos(v.camera.yaw);
    final double sp = math.sin(v.camera.pitch), cp = math.cos(v.camera.pitch);
    final double ox = v.camera.x, oy = v.camera.y, oz = v.camera.z;
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
      old.scene != scene || old.camera != camera;
}

class _View {
  _View({
    required this.camera,
    required this.focal,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });

  final FlyCamera camera;
  final double focal, cx, cy, width, height;
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
