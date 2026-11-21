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
    this.tearRatio = 1.08,
    this.occluderRatio = 1.12,
    this.textureLongSide = 2048,
    this.backgroundTextureLongSide = 512,
    this.maxParticles = 24000,
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
  /// separating objects and breaking blurry grazing-angle stretches into
  /// characteristic-colored particles.
  final double tearRatio;

  /// A point counts as an occluder when its local background is at least
  /// this many times farther away.
  final double occluderRatio;

  final int textureLongSide;
  final int backgroundTextureLongSide;

  /// Soft cap on generated particles in occluded / torn regions.
  final int maxParticles;
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

    final _MeshResult r = await compute(
      _buildMeshes,
      _MeshInput(
        disparity: depth.values,
        dw: depth.width,
        dh: depth.height,
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

    final ui.Image texture = await rgbaToImage(r.fgRgba, tw, th);
    final bool needsNativePng =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    final Uint8List fgPng =
        needsNativePng ? await encodePng(texture) : Uint8List(0);
    final SceneLayer fg = SceneLayer(
      positions: r.fgPositions,
      uvs: r.uvs,
      indices: r.fgIndices,
      texture: texture,
      texturePng: fgPng,
    );

    ParticleCloud? particles;
    if (r.particleSizes.isNotEmpty) {
      particles = ParticleCloud(
        positions: r.particlePositions,
        colors: r.particleColors,
        sizes: r.particleSizes,
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
      particles: particles,
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
    required this.particlePositions,
    required this.particleColors,
    required this.particleSizes,
    required this.introPositions,
    required this.introColors,
    required this.introSizes,
  });

  final Float32List fgPositions;
  final Float32List uvs;
  final Int32List fgIndices;
  final Uint8List fgRgba;
  final Float32List particlePositions;
  final Uint8List particleColors;
  final Float32List particleSizes;
  final Float32List introPositions;
  final Uint8List introColors;
  final Float32List introSizes;
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

  // Local background disparity: the farthest surface within a wide radius
  // (using O(N) sliding-window min filter), smoothed. Pixels clearly nearer
  // than it are occluders.
  final int radius = math.max(3, (gw * 0.16).round());
  Float32List bgG = minFilter(g, gw, gh, radius);
  final int blurR = math.max(1, (gw * 0.025).round());
  bgG = boxBlur(boxBlur(bgG, gw, gh, blurR), gw, gh, blurR);
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

  // Triangulate; tear the foreground where depth jumps or stretches steeply.
  final List<int> fgIdx = <int>[];
  final Uint8List tornCell = Uint8List(n);
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

  // Build tight rounded-corner alpha feathering on torn occluder boundaries
  // plus gentle rounded outer corners so every 3D seam transitions smoothly.
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

      // Subtle rounded corners on the outer frame in 3D space.
      double outerAlpha = 1.0;
      if ((px < outerRadiusPx || px > tw - 1 - outerRadiusPx) &&
          (py < outerRadiusPx || py > th - 1 - outerRadiusPx)) {
        final double cx = px < outerRadiusPx ? outerRadiusPx : tw - 1 - outerRadiusPx;
        final double cy = py < outerRadiusPx ? outerRadiusPx : th - 1 - outerRadiusPx;
        final double d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
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
        fgRgbaOut[(py * tw + px) * 4 + 3] =
            (finalAlpha * 255.0).round().clamp(0, 255);
      }
    }
  }

  // Erode occluder mask to erase foreground colors from the inner hole,
  // then compute push-pull fallback colors.
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

  // Replace the blurry occluded / torn regions with crisp characteristic-colored
  // 3D particles sampled directly from surrounding valid background pixels.
  final ({Float32List pos, Uint8List col, Float32List size}) particles =
      _buildParticles(
        gw: gw,
        gh: gh,
        imgW: imgW,
        imgH: imgH,
        f: f,
        zbg: zbg,
        occ: occ,
        bgMask: bgMask,
        tornCell: tornCell,
        holeGrid: holeGrid,
        origRgba: input.bgRgba,
        filledRgba: filled,
        bw: input.bw,
        bh: input.bh,
        maxParticles: o.maxParticles,
      );

  // Build 3D surface assembly particles sampled across the reconstructed 3D
  // foreground mesh so the intro animation can fly particles straight to their
  // exact 3D model coordinates.
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
    particlePositions: particles.pos,
    particleColors: particles.col,
    particleSizes: particles.size,
    introPositions: intro.pos,
    introColors: intro.col,
    introSizes: intro.size,
  );
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

({Float32List pos, Uint8List col, Float32List size}) _buildParticles({
  required int gw,
  required int gh,
  required double imgW,
  required double imgH,
  required double f,
  required Float32List zbg,
  required Uint8List occ,
  required Uint8List bgMask,
  required Uint8List tornCell,
  required Uint8List holeGrid,
  required Uint8List origRgba,
  required Uint8List filledRgba,
  required int bw,
  required int bh,
  required int maxParticles,
}) {
  final int n = gw * gh;
  final Uint8List particleMask = Uint8List(n);
  int maskedCells = 0;
  for (int i = 0; i < n; i++) {
    if (bgMask[i] == 1 || tornCell[i] == 1) {
      particleMask[i] = 1;
      maskedCells++;
    }
  }
  if (maskedCells == 0) {
    return (
      pos: Float32List(0),
      col: Uint8List(0),
      size: Float32List(0),
    );
  }

  // Cells strictly belonging to genuine background (not inside occluders or
  // torn foreground edges) provide crisp characteristic color samples.
  final Uint8List validBg = Uint8List(n);
  int validCount = 0;
  for (int i = 0; i < n; i++) {
    if (occ[i] == 0 && tornCell[i] == 0) {
      validBg[i] = 1;
      validCount++;
    }
  }
  if (validCount == 0) {
    for (int i = 0; i < n; i++) {
      if (holeGrid[i] == 0) {
        validBg[i] = 1;
        validCount++;
      }
    }
  }

  // Precompute 8-directional nearest valid background cells in O(N).
  const List<int> dirDx = <int>[-1, 1, 0, 0, -1, 1, -1, 1];
  const List<int> dirDy = <int>[0, 0, -1, 1, -1, -1, 1, 1];
  final List<Int32List> hitIdx = List<Int32List>.generate(
    8,
    (_) => Int32List(n)..fillRange(0, n, -1),
  );
  final List<Int32List> hitDist = List<Int32List>.generate(
    8,
    (_) => Int32List(n)..fillRange(0, n, 1 << 20),
  );

  for (int d = 0; d < 8; d++) {
    final int dx = dirDx[d];
    final int dy = dirDy[d];
    final Int32List hi = hitIdx[d];
    final Int32List hd = hitDist[d];
    // Sweep in the direction opposite to (dx, dy) so neighbor (x + dx, y + dy)
    // is already computed.
    final int xStart = dx > 0 ? gw - 1 : 0;
    final int xEnd = dx > 0 ? -1 : gw;
    final int xStep = dx > 0 ? -1 : 1;
    final int yStart = dy > 0 ? gh - 1 : 0;
    final int yEnd = dy > 0 ? -1 : gh;
    final int yStep = dy > 0 ? -1 : 1;

    for (int y = yStart; y != yEnd; y += yStep) {
      for (int x = xStart; x != xEnd; x += xStep) {
        final int i = y * gw + x;
        if (validBg[i] == 1) {
          hi[i] = i;
          hd[i] = 0;
          continue;
        }
        final int nx = x + dx;
        final int ny = y + dy;
        if (nx >= 0 && nx < gw && ny >= 0 && ny < gh) {
          final int ni = ny * gw + nx;
          if (hi[ni] >= 0) {
            hi[i] = hi[ni];
            hd[i] = hd[ni] + 1;
          }
        }
      }
    }
  }

  // Pack more small uniform particles cleanly in a stratified sub-grid.
  final int samplesPerCell;
  final int cellStep;
  if (maskedCells * 4 <= maxParticles) {
    samplesPerCell = 4;
    cellStep = 1;
  } else if (maskedCells * 3 <= maxParticles) {
    samplesPerCell = 3;
    cellStep = 1;
  } else if (maskedCells * 2 <= maxParticles) {
    samplesPerCell = 2;
    cellStep = 1;
  } else if (maskedCells <= maxParticles) {
    samplesPerCell = 1;
    cellStep = 1;
  } else {
    samplesPerCell = 1;
    cellStep = math.max(2, math.sqrt(maskedCells / maxParticles).ceil());
  }

  final int capacity = maskedCells * samplesPerCell;
  final Float32List outPos = Float32List(capacity * 3);
  final Uint8List outCol = Uint8List(capacity * 4);
  final Float32List outSize = Float32List(capacity);

  double hash01(int a, int b, int c) {
    int h = a * 374761393 + b * 668265263 + c * 2147483647;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= (h >> 16);
    return (h & 0x00FFFFFF) / 16777216.0;
  }

  double sampleZbg(double gx, double gy) {
    final double cx = gx.clamp(0.0, (gw - 1).toDouble());
    final double cy = gy.clamp(0.0, (gh - 1).toDouble());
    final int x0 = cx.floor();
    final int y0 = cy.floor();
    final int x1 = math.min(gw - 1, x0 + 1);
    final int y1 = math.min(gh - 1, y0 + 1);
    final double fx = cx - x0;
    final double fy = cy - y0;
    final double a = zbg[y0 * gw + x0];
    final double b = zbg[y0 * gw + x1];
    final double c = zbg[y1 * gw + x0];
    final double d = zbg[y1 * gw + x1];
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
  }

  final List<int> candRgb = List<int>.filled(24, 0);
  final List<double> candWeight = List<double>.filled(8, 0.0);

  // Uniform angular particle radius so every particle has the exact same
  // crisp small size.
  final double uniformAngularRadius = (imgW / f) / gw * 0.22;

  int count = 0;
  for (int gy = 0; gy < gh; gy += cellStep) {
    for (int gx = 0; gx < gw; gx += cellStep) {
      final int cellIdx = gy * gw + gx;
      if (particleMask[cellIdx] == 0) continue;

      // Gather directional characteristic background colors around this cell.
      int candCount = 0;
      double weightSum = 0.0;
      for (int d = 0; d < 8; d++) {
        final int hit = hitIdx[d][cellIdx];
        if (hit < 0) continue;
        int hx = hit % gw;
        int hy = hit ~/ gw;
        // Step deeper into valid background to avoid edge fringe.
        for (int step = 0; step < 3; step++) {
          final int sx = hx + dirDx[d];
          final int sy = hy + dirDy[d];
          if (sx >= 0 && sx < gw && sy >= 0 && sy < gh && validBg[sy * gw + sx] == 1) {
            hx = sx;
            hy = sy;
          } else {
            break;
          }
        }
        final int bx = (hx / (gw - 1) * (bw - 1)).round().clamp(0, bw - 1);
        final int by = (hy / (gh - 1) * (bh - 1)).round().clamp(0, bh - 1);
        final int p = (by * bw + bx) * 4;
        final double w = 1.0 / (hitDist[d][cellIdx] + 1.5);
        candRgb[candCount * 3] = origRgba[p];
        candRgb[candCount * 3 + 1] = origRgba[p + 1];
        candRgb[candCount * 3 + 2] = origRgba[p + 2];
        candWeight[candCount] = w;
        weightSum += w;
        candCount++;
      }

      final int fbx = (gx / (gw - 1) * (bw - 1)).round().clamp(0, bw - 1);
      final int fby = (gy / (gh - 1) * (bh - 1)).round().clamp(0, bh - 1);
      final int fp = (fby * bw + fbx) * 4;
      final int baseR = filledRgba[fp];
      final int baseG = filledRgba[fp + 1];
      final int baseB = filledRgba[fp + 2];

      for (int s = 0; s < samplesPerCell; s++) {
        if (count >= capacity) break;
        // Stratified sub-cell positions (2x2 for 4 samples, diagonal for 2-3).
        final double baseOx;
        final double baseOy;
        if (samplesPerCell == 4) {
          baseOx = (s % 2 == 0) ? -0.26 : 0.26;
          baseOy = (s < 2) ? -0.26 : 0.26;
        } else if (samplesPerCell == 3) {
          baseOx = (s - 1) * 0.28;
          baseOy = (s == 1 ? -0.26 : 0.22);
        } else if (samplesPerCell == 2) {
          baseOx = s == 0 ? -0.24 : 0.24;
          baseOy = s == 0 ? 0.24 : -0.24;
        } else {
          baseOx = 0.0;
          baseOy = 0.0;
        }
        final double jx = (baseOx + (hash01(gx, gy, s * 7 + 1) - 0.5) * 0.56) * cellStep;
        final double jy = (baseOy + (hash01(gx, gy, s * 7 + 2) - 0.5) * 0.56) * cellStep;
        final double jz = hash01(gx, gy, s * 7 + 3) * 0.045;
        final double jc = hash01(gx, gy, s * 7 + 5);
        final double jb = hash01(gx, gy, s * 7 + 6);

        final double sgx = (gx + jx).clamp(0.0, (gw - 1).toDouble());
        final double sgy = (gy + jy).clamp(0.0, (gh - 1).toDouble());
        final double u = sgx / (gw - 1);
        final double v = sgy / (gh - 1);
        final double px = (u - 0.5) * imgW / f;
        final double py = (v - 0.5) * imgH / f;
        final double z = sampleZbg(sgx, sgy) * (1.01 + jz);

        outPos[count * 3] = px * z;
        outPos[count * 3 + 1] = -py * z;
        outPos[count * 3 + 2] = -z;

        // Every particle has identical uniform crisp small radius.
        outSize[count] = uniformAngularRadius * z;

        // Pick a pure characteristic pixel color from surrounding background rays.
        int r = baseR;
        int g = baseG;
        int b = baseB;
        if (candCount > 0 && weightSum > 0) {
          double target = jc * weightSum;
          int picked = candCount - 1;
          for (int k = 0; k < candCount; k++) {
            target -= candWeight[k];
            if (target <= 0) {
              picked = k;
              break;
            }
          }
          r = candRgb[picked * 3];
          g = candRgb[picked * 3 + 1];
          b = candRgb[picked * 3 + 2];
        }

        // Clean, crisp characteristic hue without blurry muddiness.
        final double lum = 0.299 * r + 0.587 * g + 0.114 * b;
        const double satBoost = 1.18;
        final double bright = 0.92 + jb * 0.18;
        final int fr = ((lum + (r - lum) * satBoost) * bright).round().clamp(0, 255);
        final int fg = ((lum + (g - lum) * satBoost) * bright).round().clamp(0, 255);
        final int fb = ((lum + (b - lum) * satBoost) * bright).round().clamp(0, 255);

        outCol[count * 4] = fr;
        outCol[count * 4 + 1] = fg;
        outCol[count * 4 + 2] = fb;
        outCol[count * 4 + 3] = 242;
        count++;
      }
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
