import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../depth/depth_map.dart';
import 'image_utils.dart';
import 'photo_scene.dart';

/// Tunables for turning a photo + relative depth into metric-ish geometry.
class SceneBuildOptions {
  const SceneBuildOptions({
    this.gridLongSide = 224,
    this.nearMeters = 1.2,
    this.farMeters = 9.0,
    this.focalFactor = 0.8,
    this.tearRatio = 1.10,
    this.occluderRatio = 1.12,
    this.textureLongSide = 2048,
    this.backgroundTextureLongSide = 512,
  });

  /// Number of grid vertices along the long side of the photo.
  final int gridLongSide;

  /// Distance of the nearest / farthest point of the photo, in meters.
  /// Depth models only give relative depth; these fix the scale so that
  /// walking ~1–3 m gets you "into" the picture.
  final double nearMeters;
  final double farMeters;

  /// Focal length = focalFactor * long side (≈ 64° field of view, typical of
  /// a phone main camera).
  final double focalFactor;

  /// A triangle is torn when its farthest vertex is this many times farther
  /// than its nearest one. Using a depth *ratio* (not a disparity difference)
  /// keeps steep but smooth near surfaces (a face, a cat's back) intact while
  /// still separating objects from what is behind them.
  final double tearRatio;

  /// A point counts as an occluder when its local background is at least
  /// this many times farther away.
  final double occluderRatio;

  final int textureLongSide;
  final int backgroundTextureLongSide;
}

/// Builds a [PhotoScene] from a decoded photo and its depth map.
class SceneBuilder {
  static Future<PhotoScene> build(
    ui.Image photo,
    DepthMap depth, {
    SceneBuildOptions options = const SceneBuildOptions(),
  }) async {
    final ui.Image texture = await resizeImage(photo, options.textureLongSide);
    final ({int w, int h}) bgSize = fitLongSide(
      photo.width,
      photo.height,
      options.backgroundTextureLongSide,
    );
    final Uint8List bgRgba = await imageToRgba(photo, bgSize.w, bgSize.h);

    final _MeshResult r = await compute(
      _buildMeshes,
      _MeshInput(
        disparity: depth.values,
        dw: depth.width,
        dh: depth.height,
        imageWidth: photo.width,
        imageHeight: photo.height,
        bgRgba: bgRgba,
        bw: bgSize.w,
        bh: bgSize.h,
        options: options,
      ),
    );

    final Uint8List fgPng = await encodePng(texture);
    final SceneLayer fg = SceneLayer(
      positions: r.fgPositions,
      uvs: r.uvs,
      indices: r.fgIndices,
      texture: texture,
      texturePng: fgPng,
    );

    SceneLayer? bg;
    if (r.bgIndices.isNotEmpty) {
      final ui.Image bgImage = await rgbaToImage(r.bgRgba, bgSize.w, bgSize.h);
      bg = SceneLayer(
        positions: r.bgPositions,
        uvs: r.uvs,
        indices: r.bgIndices,
        texture: bgImage,
        texturePng: await encodePng(bgImage),
      );
    }

    return PhotoScene(
      foreground: fg,
      background: bg,
      imageWidth: photo.width,
      imageHeight: photo.height,
      focalPx: options.focalFactor * math.max(photo.width, photo.height),
    );
  }
}

class _MeshInput {
  _MeshInput({
    required this.disparity,
    required this.dw,
    required this.dh,
    required this.imageWidth,
    required this.imageHeight,
    required this.bgRgba,
    required this.bw,
    required this.bh,
    required this.options,
  });

  final Float32List disparity;
  final int dw;
  final int dh;
  final int imageWidth;
  final int imageHeight;
  final Uint8List bgRgba;
  final int bw;
  final int bh;
  final SceneBuildOptions options;
}

class _MeshResult {
  _MeshResult({
    required this.fgPositions,
    required this.bgPositions,
    required this.uvs,
    required this.fgIndices,
    required this.bgIndices,
    required this.bgRgba,
  });

  final Float32List fgPositions;
  final Float32List bgPositions;
  final Float32List uvs;
  final Int32List fgIndices;
  final Int32List bgIndices;
  final Uint8List bgRgba;
}

/// Exposed for tests.
@visibleForTesting
Float32List normalizeDisparity(Float32List d) {
  final Float32List sorted = Float32List.fromList(d)..sort();
  final double lo = sorted[(sorted.length * 0.01).floor()];
  final double hi = sorted[math.min(sorted.length - 1, (sorted.length * 0.99).floor())];
  final double range = math.max(1e-6, hi - lo);
  final Float32List out = Float32List(d.length);
  for (int i = 0; i < d.length; i++) {
    out[i] = ((d[i] - lo) / range).clamp(0.0, 1.0);
  }
  return out;
}

_MeshResult _buildMeshes(_MeshInput input) {
  final SceneBuildOptions o = input.options;
  final Float32List dn = normalizeDisparity(input.disparity);

  // Grid resolution follows the photo's aspect ratio.
  final bool landscape = input.imageWidth >= input.imageHeight;
  final double aspect = input.imageWidth / input.imageHeight;
  final int gw = landscape
      ? o.gridLongSide
      : math.max(8, (o.gridLongSide * aspect).round());
  final int gh = landscape
      ? math.max(8, (o.gridLongSide / aspect).round())
      : o.gridLongSide;
  final int n = gw * gh;

  // Sample normalized disparity on the grid (bilinear).
  final Float32List g = Float32List(n);
  for (int y = 0; y < gh; y++) {
    final double sy = y / (gh - 1) * (input.dh - 1);
    final int y0 = sy.floor();
    final int y1 = math.min(input.dh - 1, y0 + 1);
    final double fy = sy - y0;
    for (int x = 0; x < gw; x++) {
      final double sx = x / (gw - 1) * (input.dw - 1);
      final int x0 = sx.floor();
      final int x1 = math.min(input.dw - 1, x0 + 1);
      final double fx = sx - x0;
      final double a = dn[y0 * input.dw + x0];
      final double b = dn[y0 * input.dw + x1];
      final double c = dn[y1 * input.dw + x0];
      final double d = dn[y1 * input.dw + x1];
      g[y * gw + x] =
          (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
    }
  }

  // Local background disparity: the farthest surface within a radius,
  // smoothed. Pixels clearly nearer than it are occluders.
  final int radius = math.max(2, (gw * 0.05).round());
  Float32List bgG = minFilter(g, gw, gh, radius);
  bgG = boxBlur(boxBlur(bgG, gw, gh, radius ~/ 2), gw, gh, radius ~/ 2);
  for (int i = 0; i < n; i++) {
    if (bgG[i] > g[i]) bgG[i] = g[i];
  }
  final double invNear = 1.0 / o.nearMeters;
  final double invFar = 1.0 / o.farMeters;
  double toZ(double disp) => 1.0 / (disp * (invNear - invFar) + invFar);
  final Float32List zg = Float32List(n);
  final Float32List zbg = Float32List(n);
  for (int i = 0; i < n; i++) {
    zg[i] = toZ(g[i]);
    zbg[i] = toZ(bgG[i]);
  }

  final Uint8List occ = Uint8List(n);
  for (int i = 0; i < n; i++) {
    if (zbg[i] > zg[i] * o.occluderRatio) occ[i] = 1;
  }
  final Uint8List bgMask = dilate(occ, gw, gh, 2);

  // Unproject grid vertices with a pinhole model.
  final double imgW = input.imageWidth.toDouble();
  final double imgH = input.imageHeight.toDouble();
  final double f = o.focalFactor * math.max(imgW, imgH);

  final Float32List fgPos = Float32List(n * 3);
  final Float32List bgPos = Float32List(n * 3);
  final Float32List uvs = Float32List(n * 2);
  for (int y = 0; y < gh; y++) {
    final double v = y / (gh - 1);
    final double py = (v - 0.5) * imgH / f;
    for (int x = 0; x < gw; x++) {
      final double u = x / (gw - 1);
      final double px = (u - 0.5) * imgW / f;
      final int i = y * gw + x;
      final double zf = zg[i];
      // Push the background layer back a hair so it never z-fights the
      // foreground where both overlap.
      final double zb = zbg[i] * 1.01;
      fgPos[i * 3] = px * zf;
      fgPos[i * 3 + 1] = -py * zf;
      fgPos[i * 3 + 2] = -zf;
      bgPos[i * 3] = px * zb;
      bgPos[i * 3 + 1] = -py * zb;
      bgPos[i * 3 + 2] = -zb;
      uvs[i * 2] = u;
      uvs[i * 2 + 1] = v;
    }
  }

  // Triangulate; tear the foreground where depth jumps.
  final List<int> fgIdx = <int>[];
  final List<int> bgIdx = <int>[];
  void addTri(int a, int b, int c) {
    final double za = zg[a], zb = zg[b], zc = zg[c];
    final double zMax = math.max(za, math.max(zb, zc));
    final double zMin = math.min(za, math.min(zb, zc));
    if (zMax <= zMin * o.tearRatio) fgIdx..add(a)..add(b)..add(c);
    if (bgMask[a] == 1 || bgMask[b] == 1 || bgMask[c] == 1) {
      bgIdx..add(a)..add(b)..add(c);
    }
  }

  for (int y = 0; y < gh - 1; y++) {
    for (int x = 0; x < gw - 1; x++) {
      final int tl = y * gw + x;
      final int tr = tl + 1;
      final int bl = tl + gw;
      final int br = bl + 1;
      addTri(tl, bl, tr);
      addTri(tr, bl, br);
    }
  }

  // Background texture: erase occluder colors and fill them from the
  // surrounding background so people/objects are not "ghosted" behind
  // themselves. The outermost occluder cell keeps its original colors: the
  // torn cells on a silhouette show the background layer, and keeping the
  // real pixels there makes the start view seamless (no stair-step edges).
  final Uint8List holeGrid = erode(occ, gw, gh, 1);
  final Uint8List hole = Uint8List(input.bw * input.bh);
  for (int y = 0; y < input.bh; y++) {
    final int gy = (y / (input.bh - 1) * (gh - 1)).round();
    for (int x = 0; x < input.bw; x++) {
      final int gx = (x / (input.bw - 1) * (gw - 1)).round();
      hole[y * input.bw + x] = holeGrid[gy * gw + gx];
    }
  }
  final Uint8List filled = pushPullFill(
    input.bgRgba,
    hole,
    input.bw,
    input.bh,
  );

  return _MeshResult(
    fgPositions: fgPos,
    bgPositions: bgPos,
    uvs: uvs,
    fgIndices: Int32List.fromList(fgIdx),
    bgIndices: Int32List.fromList(bgIdx),
    bgRgba: filled,
  );
}

/// Separable min filter (keeps the farthest = smallest disparity).
@visibleForTesting
Float32List minFilter(Float32List src, int w, int h, int r) {
  final Float32List tmp = Float32List(src.length);
  final Float32List out = Float32List(src.length);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double m = double.infinity;
      for (int k = math.max(0, x - r); k <= math.min(w - 1, x + r); k++) {
        final double v = src[y * w + k];
        if (v < m) m = v;
      }
      tmp[y * w + x] = m;
    }
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double m = double.infinity;
      for (int k = math.max(0, y - r); k <= math.min(h - 1, y + r); k++) {
        final double v = tmp[k * w + x];
        if (v < m) m = v;
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

@visibleForTesting
Float32List boxBlur(Float32List src, int w, int h, int r) {
  if (r <= 0) return src;
  final Float32List tmp = Float32List(src.length);
  final Float32List out = Float32List(src.length);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double s = 0;
      int c = 0;
      for (int k = math.max(0, x - r); k <= math.min(w - 1, x + r); k++) {
        s += src[y * w + k];
        c++;
      }
      tmp[y * w + x] = s / c;
    }
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double s = 0;
      int c = 0;
      for (int k = math.max(0, y - r); k <= math.min(h - 1, y + r); k++) {
        s += tmp[k * w + x];
        c++;
      }
      out[y * w + x] = s / c;
    }
  }
  return out;
}

@visibleForTesting
Uint8List dilate(Uint8List mask, int w, int h, int r) {
  final Uint8List out = Uint8List(mask.length);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (mask[y * w + x] == 0) continue;
      for (int dy = -r; dy <= r; dy++) {
        final int yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (int dx = -r; dx <= r; dx++) {
          final int xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          out[yy * w + xx] = 1;
        }
      }
    }
  }
  return out;
}

@visibleForTesting
Uint8List erode(Uint8List mask, int w, int h, int r) {
  final Uint8List inv = Uint8List(mask.length);
  for (int i = 0; i < mask.length; i++) {
    inv[i] = mask[i] == 0 ? 1 : 0;
  }
  final Uint8List grown = dilate(inv, w, h, r);
  final Uint8List out = Uint8List(mask.length);
  for (int i = 0; i < mask.length; i++) {
    out[i] = grown[i] == 0 ? 1 : 0;
  }
  return out;
}

/// Fills pixels where [hole] == 1 with colors diffused from valid pixels
/// using a push-pull image pyramid. Returns new RGBA bytes.
@visibleForTesting
Uint8List pushPullFill(Uint8List rgba, Uint8List hole, int w, int h) {
  // Level 0: premultiplied-by-weight color.
  final List<Float32List> cs = <Float32List>[];
  final List<Float32List> ws = <Float32List>[];
  final List<int> lw = <int>[];
  final List<int> lh = <int>[];

  Float32List c = Float32List(w * h * 3);
  Float32List wt = Float32List(w * h);
  for (int i = 0; i < w * h; i++) {
    if (hole[i] == 0) {
      wt[i] = 1;
      c[i * 3] = rgba[i * 4].toDouble();
      c[i * 3 + 1] = rgba[i * 4 + 1].toDouble();
      c[i * 3 + 2] = rgba[i * 4 + 2].toDouble();
    }
  }
  cs.add(c);
  ws.add(wt);
  lw.add(w);
  lh.add(h);

  // Pull: average valid samples into coarser levels.
  while (lw.last > 1 || lh.last > 1) {
    final int pw = lw.last, ph = lh.last;
    final int nw = math.max(1, (pw + 1) ~/ 2), nh = math.max(1, (ph + 1) ~/ 2);
    final Float32List pc = cs.last, pwt = ws.last;
    final Float32List nc = Float32List(nw * nh * 3);
    final Float32List nwt = Float32List(nw * nh);
    for (int y = 0; y < nh; y++) {
      for (int x = 0; x < nw; x++) {
        double sr = 0, sg = 0, sb = 0, sw = 0;
        for (int dy = 0; dy < 2; dy++) {
          final int yy = math.min(ph - 1, y * 2 + dy);
          for (int dx = 0; dx < 2; dx++) {
            final int xx = math.min(pw - 1, x * 2 + dx);
            final int j = yy * pw + xx;
            final double ww = pwt[j];
            sr += pc[j * 3] * ww;
            sg += pc[j * 3 + 1] * ww;
            sb += pc[j * 3 + 2] * ww;
            sw += ww;
          }
        }
        final int k = y * nw + x;
        if (sw > 0) {
          nc[k * 3] = sr / sw;
          nc[k * 3 + 1] = sg / sw;
          nc[k * 3 + 2] = sb / sw;
        }
        nwt[k] = math.min(1.0, sw);
      }
    }
    cs.add(nc);
    ws.add(nwt);
    lw.add(nw);
    lh.add(nh);
  }

  // Push: fill each level's gaps from the (bilinearly upsampled) coarser one.
  for (int l = cs.length - 2; l >= 0; l--) {
    final int cw = lw[l], ch = lh[l];
    final int uw = lw[l + 1], uh = lh[l + 1];
    final Float32List cc = cs[l], cwt = ws[l], uc = cs[l + 1];
    for (int y = 0; y < ch; y++) {
      final double sy = math.max(0.0, math.min(uh - 1.0, (y + 0.5) / 2 - 0.5));
      final int y0 = sy.floor(), y1 = math.min(uh - 1, y0 + 1);
      final double fy = sy - y0;
      for (int x = 0; x < cw; x++) {
        final int k = y * cw + x;
        final double ww = cwt[k];
        if (ww >= 1) continue;
        final double sx = math.max(0.0, math.min(uw - 1.0, (x + 0.5) / 2 - 0.5));
        final int x0 = sx.floor(), x1 = math.min(uw - 1, x0 + 1);
        final double fx = sx - x0;
        for (int ch3 = 0; ch3 < 3; ch3++) {
          final double a = uc[(y0 * uw + x0) * 3 + ch3];
          final double b = uc[(y0 * uw + x1) * 3 + ch3];
          final double cc0 = uc[(y1 * uw + x0) * 3 + ch3];
          final double d = uc[(y1 * uw + x1) * 3 + ch3];
          final double up =
              (a * (1 - fx) + b * fx) * (1 - fy) + (cc0 * (1 - fx) + d * fx) * fy;
          cc[k * 3 + ch3] = cc[k * 3 + ch3] * ww + up * (1 - ww);
        }
        cwt[k] = 1;
      }
    }
  }

  final Uint8List out = Uint8List.fromList(rgba);
  final Float32List c0 = cs[0];
  for (int i = 0; i < w * h; i++) {
    if (hole[i] == 0) continue;
    out[i * 4] = c0[i * 3].round().clamp(0, 255);
    out[i * 4 + 1] = c0[i * 3 + 1].round().clamp(0, 255);
    out[i * 4 + 2] = c0[i * 3 + 2].round().clamp(0, 255);
    out[i * 4 + 3] = 255;
  }
  return out;
}
