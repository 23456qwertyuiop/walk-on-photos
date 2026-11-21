import 'dart:typed_data';

/// Relative inverse depth (disparity) as produced by Depth Anything:
/// larger value = closer to the camera. Row-major, [width] x [height].
class DepthMap {
  DepthMap(this.width, this.height, this.values)
    : assert(values.length == width * height);

  final int width;
  final int height;
  final Float32List values;
}
