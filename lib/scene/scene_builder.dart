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
    this.skyMeters = 80.0,
    this.skyRatio = 0.02,
    this.focalFactor = 0.8,
    this.tearRatio = 1.08,
    this.occluderRatio = 1.12,
    this.guideRadius = 3,
    this.guideEps = 0.0025,
    this.ringFraction = 0.18,
    this.textureLongSide = 2048,
    this.backgroundTextureLongSide = 1024,
  });

  /// Number of grid vertices along the long side of the photo.
  final int gridLongSide;

  /// Distance of the nearest / farthest (non-sky) point of the photo, in
  /// meters. Depth models only give relative depth; these fix the scale so
  /// that walking ~1–3 m gets you "into" the picture.
  final double nearMeters;
  final double farMeters;

  /// Sky (raw disparity ≈ 0) is pushed out to this distance so it behaves
  /// like a real sky: no parallax, it never "comes closer" as you walk.
  final double skyMeters;

  /// Raw disparity below `skyRatio * p99` counts as sky. Depth Anything
  /// returns ~0 for sky, while indoor back walls stay well above this.
  final double skyRatio;

  /// Focal length = focalFactor * long side (≈ 64° field of view, typical of
  /// a phone main camera).
  final double focalFactor;

  /// A triangle is torn when its farthest vertex is this many times farther
  /// than its nearest one. Using a depth *ratio* (not a disparity difference)
  /// keeps steep but smooth near surfaces (a face, a cat's back) intact while
  /// separating objects from what is behind them.
  final double tearRatio;

  /// A point counts as an occluder when its local background is at least
  /// this many times farther away.
  final double occluderRatio;

  /// Guided-filter radius (depth-map pixels) and regularization used to snap
  /// depth edges onto color edges of the photo.
  final int guideRadius;
  final double guideEps;

  /// Width of the soft "beyond the frame" extension, as a fraction of the
  /// grid, so turning your head does not hit a hard black cut.
  final double ringFraction;

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
    final ui.Image rawTexture = await resizeImage(photo, options.textureLongSide);
    final ({int w, int h}) bgSize = fitLongSide(
      photo.width,
      photo.height,
      options.backgroundTextureLongSide,
    );
    final Uint8List fgRgba = await imageToRgba(
      rawTexture,
      rawTexture.width,
      rawTexture.height,
    );
    final int tw = rawTexture.width;
    final int th = rawTexture.height;
    rawTexture.dispose();

    final Uint8List bgRgba = await imageToRgba(photo, bgSize.w, bgSize.h);
    final Uint8List guideRgba = await imageToRgba(
      photo,
      depth.width,
      depth.height,
    );

    final _MeshResult r = await compute(
      _buildMeshes,
      _MeshInput(
        disparity: depth.values,
        dw: depth.width,
        dh: depth.height,
        guideRgba: guideRgba,
        imageWidth: photo.width,
        imageHeight: photo.height,
        fgRgba: fgRgba,
        tw: tw,
        th: th,
        bgRgba: bgRgba,
        bw: bgSize.w,
        bh: bgSize.h,
        options: options,
      ),
    );

    final bool needsNativePng =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    final ui.Image texture = await rgbaToImage(r.fgRgba, tw, th);
    final SceneLayer fg = SceneLayer(
      positions: r.fgPositions,
      uvs: r.uvs,
      indices: r.fgIndices,
      texture: texture,
      texturePng: needsNativePng ? await encodePng(texture) : Uint8List(0),
    );

    SceneLayer? bg;
    if (r.bgIndices.isNotEmpty) {
      final ui.Image bgImage = await rgbaToImage(r.bgRgba, bgSize.w, bgSize.h);
      bg = SceneLayer(
        positions: r.bgPositions,
        uvs: r.bgUvs,
        indices: r.bgIndices,
        alphas: r.bgAlphas,
        texture: bgImage,
        texturePng: needsNativePng ? await encodePng(bgImage) : Uint8List(0),
      );
    }

    ParticleCloud? introParticles;
    if (r.introSizes.isNotEmpty) {
      introParticles = ParticleCloud(
        positions: r.introPositions,
        colors: r.introColors,
        sizes: r.introSizes,
      );
    }

    return PhotoScene(
      foreground: fg,
      background: bg,
      introParticles: introParticles,
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
    required this.guideRgba,
    required this.imageWidth,
    required this.imageHeight,
    required this.fgRgba,
    required this.tw,
    required this.th,
    required this.bgRgba,
    required this.bw,
    required this.bh,
    required this.options,
  });

  final Float32List disparity;
  final int dw;
  final int dh;
  final Uint8List guideRgba;
  final int imageWidth;
  final int imageHeight;
  final Uint8List fgRgba;
  final int tw;
  final int th;
  final Uint8List bgRgba;
  final int bw;
  final int bh;
  final SceneBuildOptions options;
}

class _MeshResult {
  _MeshResult({
    required this.fgPositions,
    required this.uvs,
    required this.fgIndices,
    required this.fgRgba,
    required this.bgPositions,
    required this.bgUvs,
    required this.bgAlphas,
    required this.bgIndices,
    required this.bgRgba,
    required this.introPositions,
    required this.introColors,
    required this.introSizes,
  });

  final Float32List fgPositions;
  final Float32List uvs;
  final Int32List fgIndices;
  final Uint8List fgRgba;
  final Float32List bgPositions;
  final Float32List bgUvs;
  final Float32List bgAlphas;
  final Int32List bgIndices;
  final Uint8List bgRgba;
  final Float32List introPositions;
  final Uint8List introColors;
  final Float32List introSizes;
}

double _percentile(Float32List values, double p) {
  final Float32List sorted = Float32List.fromList(values)..sort();
  if (sorted.isEmpty) return 0;
  return sorted[(sorted.length * p).floor().clamp(0, sorted.length - 1)];
}

/// Exposed for tests.
@visibleForTesting
Float32List normalizeDisparity(Float32List d) {
  final double lo = _percentile(d, 0.01);
  final double hi = _percentile(d, 0.99);
  final double range = math.max(1e-6, hi - lo);
  final Float32List out = Float32List(d.length);
  for (int i = 0; i < d.length; i++) {
    out[i] = ((d[i] - lo) / range).clamp(0.0, 1.0);
  }
  return out;
}

_MeshResult _buildMeshes(_MeshInput input) {
  final SceneBuildOptions o = input.options;
  final int dw = input.dw, dh = input.dh;
  final Float32List raw = input.disparity;

  // 1. Sky detection on the raw model output, then normalize the rest of the
  //    scene so its nearest/farthest points map to near/far meters.
  final double p99 = _percentile(raw, 0.99);
  final Float32List sky = Float32List(dw * dh);
  final List<double> nonSky = <double>[];
  for (int i = 0; i < raw.length; i++) {
    if (raw[i] < o.skyRatio * p99) {
      sky[i] = 1;
    } else {
      nonSky.add(raw[i]);
    }
  }
  final Float32List nonSkyList = Float32List.fromList(
    nonSky.isEmpty ? <double>[0, 1] : nonSky,
  );
  final double lo = _percentile(nonSkyList, 0.01);
  final double hi = _percentile(nonSkyList, 0.99);
  final double range = math.max(1e-6, hi - lo);
  Float32List dn = Float32List(raw.length);
  for (int i = 0; i < raw.length; i++) {
    dn[i] = ((raw[i] - lo) / range).clamp(0.0, 1.0);
  }

  // 2. Snap depth edges to the photo's color edges (guided filter). The
  //    model predicts at ~518 px, so its edges are soft and slightly off;
  //    without this, objects tear a few pixels away from their outline and
  //    drag background pixels along (dark/ghost fringes).
  final Float32List guide = Float32List(dw * dh);
  for (int i = 0; i < dw * dh; i++) {
    final int p = i * 4;
    guide[i] =
        (0.299 * input.guideRgba[p] +
            0.587 * input.guideRgba[p + 1] +
            0.114 * input.guideRgba[p + 2]) /
        255.0;
  }
  dn = guidedFilter(dn, guide, dw, dh, o.guideRadius, o.guideEps);

  // 3. Sample onto the mesh grid.
  final bool landscape = input.imageWidth >= input.imageHeight;
  final double aspect = input.imageWidth / input.imageHeight;
  final int gw = landscape
      ? o.gridLongSide
      : math.max(8, (o.gridLongSide * aspect).round());
  final int gh = landscape
      ? math.max(8, (o.gridLongSide / aspect).round())
      : o.gridLongSide;
  final int n = gw * gh;
  final Float32List g = _resample(dn, dw, dh, gw, gh);
  final Float32List skyG = _resample(sky, dw, dh, gw, gh);

  // Work in inverse depth q = 1/z (meters^-1): linear in disparity, and a
  // plane in the world is linear in q across the image — handy for the
  // beyond-the-frame extrapolation below.
  final double invNear = 1.0 / o.nearMeters;
  final double invFar = 1.0 / o.farMeters;
  final double invSky = 1.0 / o.skyMeters;
  final Float32List q = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double qScene = g[i] * (invNear - invFar) + invFar;
    // Soft blend at the horizon so the skyline tears cleanly.
    q[i] = skyG[i] > 0.5 ? invSky : qScene;
  }
  final Float32List zg = Float32List(n);
  for (int i = 0; i < n; i++) {
    zg[i] = 1.0 / q[i];
  }

  // 4. Local background: the farthest surface within a wide radius,
  //    smoothed. Points clearly nearer than it are occluders.
  final int radius = math.max(3, (gw * 0.16).round());
  Float32List qbg = minFilter(q, gw, gh, radius);
  final int blurR = math.max(1, (gw * 0.025).round());
  qbg = boxBlur(boxBlur(qbg, gw, gh, blurR), gw, gh, blurR);
  for (int i = 0; i < n; i++) {
    if (qbg[i] > q[i]) qbg[i] = q[i];
  }
  final Float32List zbg = Float32List(n);
  for (int i = 0; i < n; i++) {
    zbg[i] = 1.0 / qbg[i];
  }

  // 5. Foreground mesh: pinhole unprojection.
  final double imgW = input.imageWidth.toDouble();
  final double imgH = input.imageHeight.toDouble();
  final double f = o.focalFactor * math.max(imgW, imgH);

  final Float32List fgPos = Float32List(n * 3);
  final Float32List uvs = Float32List(n * 2);
  for (int y = 0; y < gh; y++) {
    final double v = y / (gh - 1);
    final double py = (v - 0.5) * imgH / f;
    for (int x = 0; x < gw; x++) {
      final double u = x / (gw - 1);
      final double px = (u - 0.5) * imgW / f;
      final int i = y * gw + x;
      final double zf = zg[i];
      fgPos[i * 3] = px * zf;
      fgPos[i * 3 + 1] = -py * zf;
      fgPos[i * 3 + 2] = -zf;
      uvs[i * 2] = u;
      uvs[i * 2 + 1] = v;
    }
  }

  // Triangulate; tear the foreground where depth jumps.
  final List<int> fgIdx = <int>[];
  final Uint8List tornCell = Uint8List(n);
  final Uint8List nearSide = Uint8List(n);
  void addTri(int a, int b, int c) {
    final double za = zg[a], zb = zg[b], zc = zg[c];
    final double zMax = math.max(za, math.max(zb, zc));
    final double zMin = math.min(za, math.min(zb, zc));
    if (zMax <= zMin * o.tearRatio) {
      fgIdx
        ..add(a)
        ..add(b)
        ..add(c);
    } else {
      tornCell[a] = 1;
      tornCell[b] = 1;
      tornCell[c] = 1;
      // Vertices on the near side of the break stand in front of something.
      final double split = zMin * math.sqrt(o.tearRatio);
      if (za < split) nearSide[a] = 1;
      if (zb < split) nearSide[b] = 1;
      if (zc < split) nearSide[c] = 1;
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

  // Prune protruding corner/tooth triangles along torn edges so silhouettes
  // lose stiff sawtooth spikes and curve more smoothly.
  List<int> activeIdx = fgIdx;
  for (int pass = 0; pass < 2; pass++) {
    final Int32List deg = Int32List(n);
    for (int t = 0; t < activeIdx.length; t++) {
      deg[activeIdx[t]]++;
    }
    final List<int> pruned = <int>[];
    for (int t = 0; t < activeIdx.length; t += 3) {
      final int a = activeIdx[t], b = activeIdx[t + 1], c = activeIdx[t + 2];
      bool isBorderVertex(int vi) {
        final int vx = vi % gw, vy = vi ~/ gw;
        return vx == 0 || vx == gw - 1 || vy == 0 || vy == gh - 1;
      }

      final int maxAllowed = pass == 0 ? 2 : 1;
      final bool spike =
          (deg[a] <= maxAllowed && tornCell[a] == 1 && !isBorderVertex(a)) ||
          (deg[b] <= maxAllowed && tornCell[b] == 1 && !isBorderVertex(b)) ||
          (deg[c] <= maxAllowed && tornCell[c] == 1 && !isBorderVertex(c));
      if (!spike) {
        pruned
          ..add(a)
          ..add(b)
          ..add(c);
      } else {
        tornCell[a] = 1;
        tornCell[b] = 1;
        tornCell[c] = 1;
      }
    }
    activeIdx = pruned;
  }

  // Occluders: nearer than their local background AND close to an actual
  // depth break. A smoothly receding floor is "nearer than the far trees"
  // too, but nothing is hidden behind it, so it must keep its real texture.
  final Uint8List nearEdge = dilate(
    tornCell,
    gw,
    gh,
    math.max(2, (gw * 0.04).round()),
  );
  final Uint8List occ = Uint8List(n);
  for (int i = 0; i < n; i++) {
    if (nearEdge[i] == 1 && zbg[i] > zg[i] * o.occluderRatio) occ[i] = 1;
  }

  // What is behind an occluder is best guessed from its immediate
  // surroundings (the floor around someone's feet, the wall beside their
  // head), not from the farthest point in a wide radius.
  // Everything that stands in front of its surroundings gets a
  // hidden-surface depth, so the background layer never mixes near and far
  // vertices in one triangle.
  final Uint8List nearSideWide = dilate(nearSide, gw, gh, 1);
  // Objects = regions cut off from the rest of the scene by tears and lying
  // on the near side of them (a cat, a person, a whole stop sign). A floor
  // or a blanket recedes smoothly into the wall behind it, so it stays
  // connected to the background and is never treated as an object.
  final Uint8List objects = _or(
    findOccluderObjects(zg, gw, gh, o.tearRatio),
    findOccluderSpans(zg, gw, gh, o.tearRatio),
  );
  final Uint8List hiddenMask = Uint8List(n);
  for (int i = 0; i < n; i++) {
    if (objects[i] == 1 || (nearSideWide[i] == 1 && zg[i] < zbg[i])) {
      hiddenMask[i] = 1;
    }
  }
  final Float32List qHidden = pushPullScalar(q, hiddenMask, gw, gh);
  final Float32List zHidden = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double qh = hiddenMask[i] == 1 ? math.min(qHidden[i], q[i]) : q[i];
    zHidden[i] = 1.0 / qh;
  }

  // Soft alpha on torn silhouettes and rounded outer corners. The background
  // layer below keeps the original pixels along these seams, so the start
  // view still reproduces the photo exactly.
  final Float32List fgKeep = Float32List(n);
  for (final int vi in activeIdx) {
    fgKeep[vi] = 1.0;
  }
  final Float32List smoothKeep = boxBlur(
    boxBlur(fgKeep, gw, gh, 1),
    gw,
    gh,
    1,
  );
  final Uint8List nearTear = dilate(tornCell, gw, gh, 2);
  final Uint8List fgRgbaOut = Uint8List.fromList(input.fgRgba);
  final int tw = input.tw, th = input.th;
  final double outerRadiusPx = math.min(tw, th) * 0.035;
  for (int py = 0; py < th; py++) {
    final double gy = py / math.max(1, th - 1) * (gh - 1);
    final int y0 = gy.floor(), y1 = math.min(gh - 1, y0 + 1);
    final double fy = gy - y0;
    for (int px = 0; px < tw; px++) {
      final double gx = px / math.max(1, tw - 1) * (gw - 1);
      final int x0 = gx.floor(), x1 = math.min(gw - 1, x0 + 1);
      final double fx = gx - x0;

      double outerAlpha = 1.0;
      if ((px < outerRadiusPx || px > tw - 1 - outerRadiusPx) &&
          (py < outerRadiusPx || py > th - 1 - outerRadiusPx)) {
        final double cx = px < outerRadiusPx
            ? outerRadiusPx
            : tw - 1 - outerRadiusPx;
        final double cy = py < outerRadiusPx
            ? outerRadiusPx
            : th - 1 - outerRadiusPx;
        final double d = math.sqrt(
          (px - cx) * (px - cx) + (py - cy) * (py - cy),
        );
        if (d > outerRadiusPx - 2.0) {
          outerAlpha = ((outerRadiusPx - d) / 2.0).clamp(0.0, 1.0);
        }
      }

      double seamAlpha = 1.0;
      if ((nearTear[y0 * gw + x0] == 1 ||
              nearTear[y0 * gw + x1] == 1 ||
              nearTear[y1 * gw + x0] == 1 ||
              nearTear[y1 * gw + x1] == 1) &&
          gx >= 1.5 &&
          gx <= gw - 2.5 &&
          gy >= 1.5 &&
          gy <= gh - 2.5) {
        final double k =
            (smoothKeep[y0 * gw + x0] * (1 - fx) +
                    smoothKeep[y0 * gw + x1] * fx) *
                (1 - fy) +
            (smoothKeep[y1 * gw + x0] * (1 - fx) +
                    smoothKeep[y1 * gw + x1] * fx) *
                fy;
        if (k < 0.52) {
          final double t = ((k - 0.12) / (0.52 - 0.12)).clamp(0.0, 1.0);
          seamAlpha = t * t * (3.0 - 2.0 * t);
        }
      }

      final double finalAlpha = math.min(outerAlpha, seamAlpha);
      if (finalAlpha < 0.999) {
        fgRgbaOut[(py * tw + px) * 4 + 3] = (finalAlpha * 255.0)
            .round()
            .clamp(0, 255);
      }
    }
  }

  // 6. Background layer, part A — what is hidden behind objects: a smooth
  //    surface at the local background depth, textured with an inpainted
  //    copy of the photo (objects erased, texture continued from the
  //    surrounding background), so moving sideways reveals a plausible wall
  //    / floor / foliage instead of a black hole.
  final Uint8List fillMask = dilate(
    _or(hiddenMask, tornCell),
    gw,
    gh,
    2,
  );
  final List<double> bgPosList = <double>[];
  final List<double> bgUvList = <double>[];
  final List<double> bgAlphaList = <double>[];
  final List<int> bgIdx = <int>[];

  final Int32List holeVert = Int32List(n)..fillRange(0, n, -1);
  int addBgVertex(double u, double v, double z, double tu, double tv, double a) {
    final double px = (u - 0.5) * imgW / f;
    final double py = (v - 0.5) * imgH / f;
    bgPosList
      ..add(px * z)
      ..add(-py * z)
      ..add(-z);
    bgUvList
      ..add(tu)
      ..add(tv);
    bgAlphaList.add(a);
    return bgAlphaList.length - 1;
  }

  int holeVertex(int x, int y) {
    final int i = y * gw + x;
    if (holeVert[i] >= 0) return holeVert[i];
    final double u = x / (gw - 1), v = y / (gh - 1);
    // Pushed back a hair so it never z-fights the foreground.
    return holeVert[i] = addBgVertex(u, v, zHidden[i] * 1.01, u, v, 1.0);
  }

  for (int y = 0; y < gh - 1; y++) {
    for (int x = 0; x < gw - 1; x++) {
      final int tl = y * gw + x;
      if (fillMask[tl] == 0 &&
          fillMask[tl + 1] == 0 &&
          fillMask[tl + gw] == 0 &&
          fillMask[tl + gw + 1] == 0) {
        continue;
      }
      final int a = holeVertex(x, y), b = holeVertex(x + 1, y);
      final int c = holeVertex(x, y + 1), d = holeVertex(x + 1, y + 1);
      bgIdx
        ..add(a)
        ..add(c)
        ..add(b)
        ..add(b)
        ..add(c)
        ..add(d);
    }
  }

  // Part B — beyond the frame: continue the scene's own surfaces past the
  // photo edges (planes extrapolated in inverse depth, mirrored texture),
  // fading out, so the photo stops looking like a card floating in a void
  // when you turn or look down at the floor.
  final int ring = math.max(2, (gw * o.ringFraction).round());
  // The floor under your feet is never in the photo: extend further down.
  final int ringBottom = ring * 2;
  final int ew = gw + ring * 2, eh = gh + ring + ringBottom;
  const int slopeSpan = 6;
  double qAt(int x, int y) => q[y.clamp(0, gh - 1) * gw + x.clamp(0, gw - 1)];
  double extrapolatedQ(int gx, int gy) {
    final int cx = gx.clamp(0, gw - 1), cy = gy.clamp(0, gh - 1);
    final double edge = qAt(cx, cy);
    if (skyG[cy * gw + cx] > 0.5) return invSky;
    double out = edge;
    if (gx < 0 || gx > gw - 1) {
      final int dir = gx < 0 ? 1 : -1; // inward
      final double slope = (edge - qAt(cx + dir * slopeSpan, cy)) / slopeSpan;
      out += slope * (gx < 0 ? -gx : gx - (gw - 1));
    }
    if (gy < 0 || gy > gh - 1) {
      final int dir = gy < 0 ? 1 : -1;
      final double slope = (edge - qAt(cx, cy + dir * slopeSpan)) / slopeSpan;
      out += slope * (gy < 0 ? -gy : gy - (gh - 1));
    }
    // Keep it physical: no closer than 0.35 m, no farther than the sky,
    // and at most 2x the edge change either way.
    return out.clamp(math.max(invSky, edge * 0.5), math.min(1 / 0.35, edge * 2));
  }

  double mirror(double t) {
    if (t < 0) return math.min(1.0, -t);
    if (t > 1) return math.max(0.0, 2 - t);
    return t;
  }

  final Int32List ringVert = Int32List(ew * eh)..fillRange(0, ew * eh, -1);
  int ringVertex(int ex, int ey) {
    final int k = ey * ew + ex;
    if (ringVert[k] >= 0) return ringVert[k];
    final int gx = ex - ring, gy = ey - ring;
    final double u = gx / (gw - 1), v = gy / (gh - 1);
    final double z = 1.0 / extrapolatedQ(gx, gy);
    final double outside = math.max(
      math.max(-gx, gx - (gw - 1)).toDouble(),
      math.max(-gy / ring * ring, (gy - (gh - 1)) * ring / ringBottom),
    );
    final double t = (1.0 - outside / ring).clamp(0.0, 1.0);
    final double alpha = outside <= 0 ? 1.0 : t * t * (3 - 2 * t);
    return ringVert[k] = addBgVertex(u, v, z, mirror(u), mirror(v), alpha);
  }

  for (int ey = 0; ey < eh - 1; ey++) {
    for (int ex = 0; ex < ew - 1; ex++) {
      final int gx = ex - ring, gy = ey - ring;
      final bool inside = gx >= 0 && gy >= 0 && gx < gw - 1 && gy < gh - 1;
      if (inside) continue;
      final int a = ringVertex(ex, ey), b = ringVertex(ex + 1, ey);
      final int c = ringVertex(ex, ey + 1), d = ringVertex(ex + 1, ey + 1);
      bgIdx
        ..add(a)
        ..add(c)
        ..add(b)
        ..add(b)
        ..add(c)
        ..add(d);
    }
  }

  // Inpainted background texture. The outermost occluder cell keeps its
  // original pixels so torn seams look identical to the photo at the start.
  // Occluder pixels (and torn seams) are never used as source material.
  // For the smooth (low-frequency) part, also avoid everything in
  // [hiddenMask] (e.g. the inside of a big stop sign), so no object color
  // bleeds into what is behind it.
  // Only erase/inpaint where the foreground is fully opaque at the start
  // view. Wherever it is torn or feathered, the background layer keeps the
  // photo's own pixels, so the first frame is exactly the photo.
  final Uint8List seamBand = dilate(tornCell, gw, gh, 1);
  final Uint8List holeGrid = Uint8List(n);
  for (int i = 0; i < n; i++) {
    if (hiddenMask[i] == 1 && seamBand[i] == 0) holeGrid[i] = 1;
  }
  final Uint8List notSourceGrid = dilate(
    _or(hiddenMask, tornCell),
    gw,
    gh,
    1,
  );
  final int bw = input.bw, bh = input.bh;
  final Uint8List hole = Uint8List(bw * bh);
  final Uint8List notSource = Uint8List(bw * bh);
  final Uint8List notSmoothSource = Uint8List(bw * bh);
  final Float32List zTex = Float32List(bw * bh);
  final Float32List zHiddenTex = Float32List(bw * bh);
  for (int y = 0; y < bh; y++) {
    final int gy = (y / (bh - 1) * (gh - 1)).round();
    for (int x = 0; x < bw; x++) {
      final int gx = (x / (bw - 1) * (gw - 1)).round();
      final int gi = gy * gw + gx, ti = y * bw + x;
      hole[ti] = holeGrid[gi];
      notSource[ti] = notSourceGrid[gi];
      notSmoothSource[ti] =
          notSourceGrid[gi] == 1 || hiddenMask[gi] == 1 ? 1 : 0;
      zTex[ti] = zg[gi];
      zHiddenTex[ti] = zHidden[gi];
    }
  }
  final Uint8List filled = inpaintTexture(
    input.bgRgba,
    hole,
    bw,
    bh,
    notSource: notSource,
    notSmoothSource: notSmoothSource,
    depth: zTex,
    hiddenDepth: zHiddenTex,
  );

  final ({Float32List pos, Uint8List col, Float32List size}) intro =
      _buildIntroParticles(
        gw: gw,
        gh: gh,
        fgPos: fgPos,
        zg: zg,
        fgRgba: fgRgbaOut,
        tw: tw,
        th: th,
        imgW: imgW,
        f: f,
      );

  return _MeshResult(
    fgPositions: fgPos,
    uvs: uvs,
    fgIndices: Int32List.fromList(activeIdx),
    fgRgba: fgRgbaOut,
    bgPositions: Float32List.fromList(bgPosList),
    bgUvs: Float32List.fromList(bgUvList),
    bgAlphas: Float32List.fromList(bgAlphaList),
    bgIndices: Int32List.fromList(bgIdx),
    bgRgba: filled,
    introPositions: intro.pos,
    introColors: intro.col,
    introSizes: intro.size,
  );
}

/// Splits the grid into surfaces connected without depth breaks and returns
/// a mask of the ones that are objects standing in front of something: on
/// the near side of most of their breaks, and not the main background.
@visibleForTesting
Uint8List findOccluderObjects(Float32List z, int w, int h, double tearRatio) {
  final int n = w * h;
  final Int32List parent = Int32List(n);
  for (int i = 0; i < n; i++) {
    parent[i] = i;
  }
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  bool joined(int a, int b) {
    final double za = z[a], zb = z[b];
    return math.max(za, zb) <= math.min(za, zb) * tearRatio;
  }

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int i = y * w + x;
      if (x + 1 < w && joined(i, i + 1)) parent[find(i)] = find(i + 1);
      if (y + 1 < h && joined(i, i + w)) parent[find(i)] = find(i + w);
    }
  }

  final Int32List size = Int32List(n);
  final Int32List nearVotes = Int32List(n);
  final Int32List farVotes = Int32List(n);
  for (int i = 0; i < n; i++) {
    size[find(i)]++;
  }
  void vote(int a, int b) {
    if (joined(a, b)) return;
    final int near = z[a] < z[b] ? a : b;
    final int far = near == a ? b : a;
    nearVotes[find(near)]++;
    farVotes[find(far)]++;
  }

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int i = y * w + x;
      if (x + 1 < w) vote(i, i + 1);
      if (y + 1 < h) vote(i, i + w);
    }
  }

  int largest = 0;
  for (int i = 0; i < n; i++) {
    if (size[i] > size[largest]) largest = i;
  }
  final Uint8List out = Uint8List(n);
  for (int i = 0; i < n; i++) {
    final int r = find(i);
    if (r == largest) continue;
    if (nearVotes[r] > 0 && nearVotes[r] >= farVotes[r]) out[i] = 1;
  }
  return out;
}

/// Scan-line object detection for things that touch the ground (people,
/// poles, signs): along each row and column, the span between stepping onto
/// a nearer surface and stepping back off it is an object. A floor recedes
/// along the view direction and never produces such a span.
@visibleForTesting
Uint8List findOccluderSpans(Float32List z, int w, int h, double tearRatio) {
  final Uint8List out = Uint8List(w * h);
  void scan(int count, int len, int Function(int line, int k) at) {
    final List<int> starts = <int>[];
    for (int line = 0; line < count; line++) {
      starts.clear();
      for (int k = 0; k + 1 < len; k++) {
        final double a = z[at(line, k)], b = z[at(line, k + 1)];
        if (b * tearRatio < a) {
          starts.add(k + 1); // stepped onto something nearer
        } else if (a * tearRatio < b && starts.isNotEmpty) {
          final int s = starts.removeLast(); // stepped back off it
          if (k - s + 1 <= len * 0.6) {
            for (int j = s; j <= k; j++) {
              out[at(line, j)] = 1;
            }
          }
        }
      }
    }
  }

  scan(h, w, (int y, int x) => y * w + x);
  scan(w, h, (int x, int y) => y * w + x);
  return out;
}

Uint8List _or(Uint8List a, Uint8List b) {
  final Uint8List out = Uint8List(a.length);
  for (int i = 0; i < a.length; i++) {
    out[i] = (a[i] | b[i]) != 0 ? 1 : 0;
  }
  return out;
}

/// Bilinear resample of a [sw]x[sh] map onto a [dw]x[dh] grid whose corner
/// samples align with the source corners.
Float32List _resample(Float32List src, int sw, int sh, int dw, int dh) {
  final Float32List out = Float32List(dw * dh);
  for (int y = 0; y < dh; y++) {
    final double sy = y / (dh - 1) * (sh - 1);
    final int y0 = sy.floor();
    final int y1 = math.min(sh - 1, y0 + 1);
    final double fy = sy - y0;
    for (int x = 0; x < dw; x++) {
      final double sx = x / (dw - 1) * (sw - 1);
      final int x0 = sx.floor();
      final int x1 = math.min(sw - 1, x0 + 1);
      final double fx = sx - x0;
      out[y * dw + x] =
          (src[y0 * sw + x0] * (1 - fx) + src[y0 * sw + x1] * fx) * (1 - fy) +
          (src[y1 * sw + x0] * (1 - fx) + src[y1 * sw + x1] * fx) * fy;
    }
  }
  return out;
}

/// Box mean with an integral image, O(N) for any radius.
Float32List _boxMean(Float32List src, int w, int h, int r) {
  final Float64List integral = Float64List((w + 1) * (h + 1));
  for (int y = 0; y < h; y++) {
    double row = 0;
    for (int x = 0; x < w; x++) {
      row += src[y * w + x];
      integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row;
    }
  }
  final Float32List out = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    final int y0 = math.max(0, y - r), y1 = math.min(h - 1, y + r) + 1;
    for (int x = 0; x < w; x++) {
      final int x0 = math.max(0, x - r), x1 = math.min(w - 1, x + r) + 1;
      final double sum =
          integral[y1 * (w + 1) + x1] -
          integral[y0 * (w + 1) + x1] -
          integral[y1 * (w + 1) + x0] +
          integral[y0 * (w + 1) + x0];
      out[y * w + x] = sum / ((x1 - x0) * (y1 - y0));
    }
  }
  return out;
}

/// Guided filter (He et al.) with a grayscale guide: edge-preserving
/// smoothing of [p] that transfers the edges of [guide] into the result.
@visibleForTesting
Float32List guidedFilter(
  Float32List p,
  Float32List guide,
  int w,
  int h,
  int r,
  double eps,
) {
  if (r <= 0) return p;
  final int n = w * h;
  final Float32List ip = Float32List(n), ii = Float32List(n);
  for (int i = 0; i < n; i++) {
    ip[i] = guide[i] * p[i];
    ii[i] = guide[i] * guide[i];
  }
  final Float32List meanI = _boxMean(guide, w, h, r);
  final Float32List meanP = _boxMean(p, w, h, r);
  final Float32List meanIp = _boxMean(ip, w, h, r);
  final Float32List meanII = _boxMean(ii, w, h, r);
  final Float32List a = Float32List(n), b = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double varI = meanII[i] - meanI[i] * meanI[i];
    final double covIp = meanIp[i] - meanI[i] * meanP[i];
    a[i] = covIp / (varI + eps);
    b[i] = meanP[i] - a[i] * meanI[i];
  }
  final Float32List meanA = _boxMean(a, w, h, r);
  final Float32List meanB = _boxMean(b, w, h, r);
  final Float32List out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = (meanA[i] * guide[i] + meanB[i]).clamp(0.0, 1.0);
  }
  return out;
}

/// Fills [hole] pixels with texture continued from both sides of each hole
/// (mirror-reflected along the row, nearer side weighted more), blended with
/// a smooth push-pull fill for the low frequencies. Keeps grain — wood floor,
/// leaves, brick — instead of a blurry smear.
@visibleForTesting
Uint8List inpaintTexture(
  Uint8List rgba,
  Uint8List hole,
  int w,
  int h, {
  Uint8List? notSource,
  Uint8List? notSmoothSource,
  Float32List? depth,
  Float32List? hiddenDepth,
}) {
  final Uint8List avoid = notSource ?? hole;
  // Smooth fill computed from allowed sources only, applied to the hole.
  final Uint8List smooth = pushPullFill(rgba, notSmoothSource ?? avoid, w, h);
  final Uint8List low = Uint8List.fromList(rgba);
  for (int i = 0; i < w * h; i++) {
    if (hole[i] == 1) {
      for (int c = 0; c < 4; c++) {
        low[i * 4 + c] = smooth[i * 4 + c];
      }
    }
  }
  final Uint8List out = Uint8List.fromList(low);
  final Uint8List done = Uint8List(w * h);
  bool valid(int x, int y) => x >= 0 && x < w && avoid[y * w + x] == 0;
  // A source may fill a hole pixel only if it is (roughly) as far away as
  // the surface hidden there — never a nearer object.
  bool deepEnough(int src, int dst) =>
      depth == null ||
      hiddenDepth == null ||
      depth[src] >= hiddenDepth[dst] * 0.85;

  for (int y = 0; y < h; y++) {
    int x = 0;
    while (x < w) {
      if (hole[y * w + x] == 0) {
        x++;
        continue;
      }
      final int a = x;
      while (x < w && hole[y * w + x] == 1) {
        x++;
      }
      final int b = x - 1; // hole run [a, b]
      // Nearest allowed source pixel on each side of the run.
      final int mid = y * w + (a + b) ~/ 2;
      int xl = a - 1, xr = b + 1;
      while (xl >= 0 &&
          (avoid[y * w + xl] == 1 || !deepEnough(y * w + xl, mid))) {
        xl--;
      }
      while (xr < w &&
          (avoid[y * w + xr] == 1 || !deepEnough(y * w + xr, mid))) {
        xr++;
      }
      for (int px = a; px <= b; px++) {
        final int dl = px - xl, dr = xr - px;
        final int sl = xl - dl + 1, sr = xr + dr - 1;
        final int here = y * w + px;
        final bool hasL =
            xl >= 0 && sl >= 0 && valid(sl, y) && deepEnough(y * w + sl, here);
        final bool hasR =
            xr < w && sr < w && valid(sr, y) && deepEnough(y * w + sr, here);
        double wl = hasL ? (dr * dr).toDouble() : 0;
        double wr = hasR ? (dl * dl).toDouble() : 0;
        final double sum = wl + wr;
        if (sum <= 0) continue; // keep push-pull value
        wl /= sum;
        wr /= sum;
        final int o = (y * w + px) * 4;
        final int ol = (y * w + (hasL ? sl : 0)) * 4;
        final int orr = (y * w + (hasR ? sr : 0)) * 4;
        for (int c = 0; c < 3; c++) {
          final double refl =
              (hasL ? rgba[ol + c] * wl : 0) + (hasR ? rgba[orr + c] * wr : 0);
          // Mostly real texture, a bit of smooth fill to hide seams.
          out[o + c] = (refl * 0.75 + low[o + c] * 0.25).round().clamp(0, 255);
        }
        out[o + 3] = 255;
        done[here] = 1;
      }
    }
  }

  // Same idea vertically for whatever the row pass could not reach (holes
  // that span the full width of their surroundings).
  for (int x = 0; x < w; x++) {
    int y = 0;
    while (y < h) {
      final int i0 = y * w + x;
      if (hole[i0] == 0 || done[i0] == 1) {
        y++;
        continue;
      }
      final int a = y;
      while (y < h && hole[y * w + x] == 1 && done[y * w + x] == 0) {
        y++;
      }
      final int b = y - 1;
      final int mid = ((a + b) ~/ 2) * w + x;
      int yt = a - 1, yb = b + 1;
      while (yt >= 0 &&
          (avoid[yt * w + x] == 1 || !deepEnough(yt * w + x, mid))) {
        yt--;
      }
      while (yb < h &&
          (avoid[yb * w + x] == 1 || !deepEnough(yb * w + x, mid))) {
        yb++;
      }
      for (int py = a; py <= b; py++) {
        final int here = py * w + x;
        final int dt = py - yt, db = yb - py;
        final int st = yt - dt + 1, sb = yb + db - 1;
        bool ok(int sy) =>
            sy >= 0 &&
            sy < h &&
            avoid[sy * w + x] == 0 &&
            deepEnough(sy * w + x, here);
        final bool hasT = yt >= 0 && ok(st);
        final bool hasB = yb < h && ok(sb);
        double wt = hasT ? (db * db).toDouble() : 0;
        double wb = hasB ? (dt * dt).toDouble() : 0;
        final double sum = wt + wb;
        if (sum <= 0) continue;
        wt /= sum;
        wb /= sum;
        final int o = here * 4;
        final int ot = (hasT ? st * w + x : 0) * 4;
        final int ob = (hasB ? sb * w + x : 0) * 4;
        for (int c = 0; c < 3; c++) {
          final double refl =
              (hasT ? rgba[ot + c] * wt : 0) + (hasB ? rgba[ob + c] * wb : 0);
          out[o + c] = (refl * 0.75 + low[o + c] * 0.25).round().clamp(0, 255);
        }
        out[o + 3] = 255;
      }
    }
  }
  return out;
}

({Float32List pos, Uint8List col, Float32List size}) _buildIntroParticles({
  required int gw,
  required int gh,
  required Float32List fgPos,
  required Float32List zg,
  required Uint8List fgRgba,
  required int tw,
  required int th,
  required double imgW,
  required double f,
}) {
  const int target = 8500;
  final int step = math.max(1, math.sqrt((gw * gh) / target).round());
  final int cols = (gw + step - 1) ~/ step;
  final int rows = (gh + step - 1) ~/ step;
  final int cap = cols * rows;

  final Float32List outPos = Float32List(cap * 3);
  final Uint8List outCol = Uint8List(cap * 4);
  final Float32List outSize = Float32List(cap);
  final double angularR = (imgW / f) / gw * 0.22;

  int count = 0;
  for (int gy = 0; gy < gh; gy += step) {
    final int py = (gy / math.max(1, gh - 1) * (th - 1)).round().clamp(0, th - 1);
    for (int gx = 0; gx < gw; gx += step) {
      final int px = (gx / math.max(1, gw - 1) * (tw - 1)).round().clamp(0, tw - 1);
      final int p = (py * tw + px) * 4;
      if (fgRgba[p + 3] < 40) continue;

      final int vi = gy * gw + gx;
      outPos[count * 3] = fgPos[vi * 3];
      outPos[count * 3 + 1] = fgPos[vi * 3 + 1];
      outPos[count * 3 + 2] = fgPos[vi * 3 + 2];

      outCol[count * 4] = fgRgba[p];
      outCol[count * 4 + 1] = fgRgba[p + 1];
      outCol[count * 4 + 2] = fgRgba[p + 2];
      outCol[count * 4 + 3] = 242;

      outSize[count] = angularR * zg[vi];
      count++;
    }
  }

  return (
    pos: Float32List.sublistView(outPos, 0, count * 3),
    col: Uint8List.sublistView(outCol, 0, count * 4),
    size: Float32List.sublistView(outSize, 0, count),
  );
}

/// Separable O(N) sliding-window min filter (keeps the farthest = smallest disparity).
@visibleForTesting
Float32List minFilter(Float32List src, int w, int h, int r) {
  if (r <= 0) return Float32List.fromList(src);
  final Float32List tmp = Float32List(src.length);
  final Float32List out = Float32List(src.length);
  final Int32List dq = Int32List(math.max(w, h) + 2);

  for (int y = 0; y < h; y++) {
    final int row = y * w;
    int head = 0, tail = 0;
    for (int x = 0; x < w + r; x++) {
      if (x < w) {
        final double v = src[row + x];
        while (tail > head && src[row + dq[tail - 1]] >= v) {
          tail--;
        }
        dq[tail++] = x;
      }
      final int c = x - r;
      if (c >= 0) {
        if (dq[head] < c - r) head++;
        tmp[row + c] = src[row + dq[head]];
      }
    }
  }

  for (int x = 0; x < w; x++) {
    int head = 0, tail = 0;
    for (int y = 0; y < h + r; y++) {
      if (y < h) {
        final double v = tmp[y * w + x];
        while (tail > head && tmp[dq[tail - 1] * w + x] >= v) {
          tail--;
        }
        dq[tail++] = y;
      }
      final int c = y - r;
      if (c >= 0) {
        if (dq[head] < c - r) head++;
        out[c * w + x] = tmp[dq[head] * w + x];
      }
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

/// Push-pull fill of a scalar field: values where [hole] == 1 are replaced
/// by a smooth interpolation of the surrounding valid values.
@visibleForTesting
Float32List pushPullScalar(Float32List src, Uint8List hole, int w, int h) {
  final List<Float32List> vs = <Float32List>[];
  final List<Float32List> ws = <Float32List>[];
  final List<int> lw = <int>[w], lh = <int>[h];
  final Float32List v0 = Float32List(w * h), w0 = Float32List(w * h);
  for (int i = 0; i < w * h; i++) {
    if (hole[i] == 0) {
      v0[i] = src[i];
      w0[i] = 1;
    }
  }
  vs.add(v0);
  ws.add(w0);
  while (lw.last > 1 || lh.last > 1) {
    final int pw = lw.last, ph = lh.last;
    final int nw = math.max(1, (pw + 1) ~/ 2), nh = math.max(1, (ph + 1) ~/ 2);
    final Float32List pv = vs.last, pwt = ws.last;
    final Float32List nv = Float32List(nw * nh), nwt = Float32List(nw * nh);
    for (int y = 0; y < nh; y++) {
      for (int x = 0; x < nw; x++) {
        double sv = 0, sw = 0;
        for (int dy = 0; dy < 2; dy++) {
          final int yy = math.min(ph - 1, y * 2 + dy);
          for (int dx = 0; dx < 2; dx++) {
            final int j = yy * pw + math.min(pw - 1, x * 2 + dx);
            sv += pv[j] * pwt[j];
            sw += pwt[j];
          }
        }
        if (sw > 0) nv[y * nw + x] = sv / sw;
        nwt[y * nw + x] = math.min(1.0, sw);
      }
    }
    vs.add(nv);
    ws.add(nwt);
    lw.add(nw);
    lh.add(nh);
  }
  for (int l = vs.length - 2; l >= 0; l--) {
    final int cw = lw[l], ch = lh[l], uw = lw[l + 1], uh = lh[l + 1];
    final Float32List cv = vs[l], cwt = ws[l], uv = vs[l + 1];
    for (int y = 0; y < ch; y++) {
      final double sy = math.max(0.0, math.min(uh - 1.0, (y + 0.5) / 2 - 0.5));
      final int y0 = sy.floor(), y1 = math.min(uh - 1, y0 + 1);
      final double fy = sy - y0;
      for (int x = 0; x < cw; x++) {
        final int k = y * cw + x;
        if (cwt[k] >= 1) continue;
        final double sx = math.max(0.0, math.min(uw - 1.0, (x + 0.5) / 2 - 0.5));
        final int x0 = sx.floor(), x1 = math.min(uw - 1, x0 + 1);
        final double fx = sx - x0;
        final double up =
            (uv[y0 * uw + x0] * (1 - fx) + uv[y0 * uw + x1] * fx) * (1 - fy) +
            (uv[y1 * uw + x0] * (1 - fx) + uv[y1 * uw + x1] * fx) * fy;
        cv[k] = cv[k] * cwt[k] + up * (1 - cwt[k]);
        cwt[k] = 1;
      }
    }
  }
  final Float32List out = Float32List.fromList(src);
  for (int i = 0; i < w * h; i++) {
    if (hole[i] == 1) out[i] = vs[0][i];
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
