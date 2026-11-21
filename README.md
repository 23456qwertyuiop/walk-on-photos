# Walk on Photos

把一张照片变成可以走进去的 3D 空间。

## 原理

1. **AI 深度**：使用端侧模型 [Depth Anything V2 Small](https://huggingface.co/onnx-community/depth-anything-v2-small)（ONNX int8，27 MB，Apache-2.0），通过 `flutter_onnxruntime` 离线运行，估算每个像素的远近。
2. **3D 重建**：按针孔相机模型把照片反投影成真实比例（约 1.2–9 m）的网格。物体与背景之间的深度断层会被撕开，避免被拉成“橡皮膜”。
3. **遮挡补全**：在物体背后补一层背景，深度取周围最远的表面，颜色用 push-pull 金字塔从周围背景扩散填充。走到物体侧面时看到的是背景，而不是黑洞或物体的重影。
4. **起点 = 拍摄点**：初始视角和原照片完全重合，之后的每一步都是真实视差。

## 各平台体验

| 设备 | 背景 | 怎么动 |
|---|---|---|
| 支持 ARKit / ARCore 的手机 | 摄像头实时画面 | 场景固定在真实房间里，**拿着手机真的往前走**就能走进照片（6DoF 追踪） |
| 不支持 AR 的手机 | 摄像头实时画面 | 陀螺仪 + 重力转视角，左下摇杆走动 |
| 电脑（macOS / Windows / Linux） | 空 | W/S 前后、A/D 左右，按住鼠标拖动看四周，Q/E 下降/上升，按住 R 奔跑，滚轮前后，F 回到拍摄点 |

## 运行

需要 Flutter 3.50+。iOS 和 macOS 需要 Xcode，Android 需要 Android Studio / SDK。

```bash
flutter pub get
flutter run -d macos      # 电脑
flutter run               # 连接的手机（AR 需真机，模拟器不支持）
```

最低系统版本：iOS 16 和 macOS 14（ONNX Runtime 的要求），Android 7.0（API 24）。

## 代码结构

- `lib/depth/`：Depth Anything 推理（预处理、ONNX 会话）
- `lib/scene/`：深度 → 分层 3D 网格、背景补全
- `lib/render/`：电脑端和无 AR 手机用的 Flutter 渲染器（透视投影、近裁剪面切割、深度排序），以及第一人称相机
- `lib/ar/` + `ios/Runner/AppDelegate.swift` + `android/.../ArPhotoView.kt`：原生 AR 视图（ARKit+SceneKit / ARCore+OpenGL ES 3，带真实深度缓冲）
- `lib/ui/`：三种模式的页面

## 用真实照片测试渲染

```bash
# 先用 Python 跑一遍模型并导出深度（见 test/widget_test.dart 里的说明）
WOP_PHOTO=photo.jpg WOP_DEPTH=photo.depth WOP_OUT=out_dir flutter test
```
