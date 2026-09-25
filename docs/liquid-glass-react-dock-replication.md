# Dock 液态玻璃复刻说明

本文说明 AlnPlay 首页 Dock 如何参考
[`rdev/liquid-glass-react`](https://github.com/rdev/liquid-glass-react) 的
`LiquidGlass` 组件，并在 Flutter 中复刻成可拖动的导航滑块。实现文件是
[`lib/widgets/liquid_glass_dock.dart`](../lib/widgets/liquid_glass_dock.dart)，
光学采样在 [`shaders/liquid_glass.frag`](../shaders/liquid_glass.frag)。

## 目标结构

Dock 由两个材质层组成：

1. **Dock 底座**：一个连续圆角的长条和一个独立的搜索圆钮。两者只做实时
   `BackdropFilter` 高斯模糊，当前 `sigma = 18`，再叠加低透明度主题色和边缘
   高光。
2. **导航滑块**：在底座内部移动的液态玻璃透镜。透镜直接采样页面背景，边缘
   做折射和 RGB 通道分离，图标和文字保持锐利地画在滤镜上方。

这两个层必须分开。若把每个按钮都做一次模糊，边界会重复取样，背景会变灰；若
把滑块画成不透明白色，拖动时就只剩普通选中胶囊，没有液态玻璃的透射感。

## 参数映射

代码把推荐参数集中在 `LiquidGlassDock` 的静态常量中，便于后续校准：

| liquid-glass-react 参数 | Flutter 值 | Flutter 中的作用 |
| --- | ---: | --- |
| `displacementScale` | `200` | shader 的边缘位移强度。因为 Flutter shader 接收归一化坐标，最终按 `200 × 0.04` 转成约 8 px 的屏幕位移，避免 64 px 高的 Dock 被采样到视口外。 |
| `blurAmount` | `0.0` | 滑块不再额外磨砂；它仍然有边缘折射。底座的高斯模糊独立使用 `dockBackdropBlurSigma = 18`。 |
| `saturation` | `150%` | 对透镜采样到的背景做 luminance 保留的饱和度混合，中心和边缘都使用同一值。 |
| `aberrationIntensity` | `9` | 以 9 为基准量化红、绿、蓝三次采样的 IOR 差异；蓝色位移最大，红色最小。 |
| `elasticity` | `0.55` | 参与拖动回弹的弹簧阻尼与透镜按压放大；按住时透镜会横向、纵向拉伸，松手后带一小段 Q 弹回落。 |

`displacementScale` 的换算不是降低参数，而是把 Web SVG 的 CSS 像素单位换成
Flutter 的视口单位。原项目的 SVG `feDisplacementMap` 会根据滤镜边界裁切，
Flutter 的 fragment shader 必须自己除以 `uViewportSize`，所以需要这一步。

## Flutter 的材质管线

### 底座高斯模糊

底座由 `_GlassSurface(lens: false)` 创建。它先把页面内容放进 `BackdropFilter`，
再绘制低透明度填充、连续圆角、顶部高光和 1 px 边线。搜索圆钮复用相同材质，
这样两个区域的模糊半径和明暗逻辑一致。

```text
page pixels
    ↓
BackdropFilter(sigmaX = 18, sigmaY = 18)
    ↓
low-alpha theme tint + shadow + edge highlight
    ↓
sharp dock labels and icons
```

### 滑块 shader

Flutter 不支持直接使用浏览器的 SVG `feDisplacementMap`，因此将同一个思路改写
成 runtime fragment shader：中心区域只采样一次背景，倒角区域按法线方向采样三次，
每次只取对应的颜色通道。

```text
point  = fragmentPosition - roundedRectAxis
depth  = radius - distance(point, roundedRectAxis)
edge   = pow(1 - depth / bevel, 1.6)

if depth >= bevel:
    color = sample(background)
else:
    normal = normalize(point - roundedRectAxis)
    pixels = 200 * 0.04
    pixels *= 1 + pressure * (0.35 + elasticity * 0.65)
    offset = normal * pixels / viewportSize

    red   = sample(background, uv - offset * bend(IORred))
    green = sample(background, uv - offset * bend(IORgreen))
    blue  = sample(background, uv - offset * bend(IORblue))
    color = vec3(red.r, green.g, blue.b)

color = mix(luminance(color), color, 1.5)
```

中心区域不做 RGB 分离，所以纯色背景不会凭空出现彩虹边缘；只有真实背景的边缘
亮度变化才会产生色散。shader 通过 `ImageFilter.compose` 先应用 `blurAmount = 0`
的滑块滤镜，再覆盖边缘采样，页面背景不会被 CPU 截图或逐帧读回。

### 为什么背景取景要留空

底座的模糊层在滑块轮廓处使用 `_DockLensCutout` 留出孔洞。这样滑块向内折射时
读取的是原始页面背景，而不是已经模糊一次的底座。如果不留空，拖动到边缘时会
出现“模糊套模糊”的灰色边，液态感会明显变弱。

## 拖动和 Q 弹

滑块位置用连续的 slot 坐标保存，例如 `0.0`、`1.0`、`2.0`，拖动过程中不强制
吸附到整数，因此透镜可以完整经过两个导航项。松手时再用速度预测目标，并交给
`SpringSimulation`。

```text
onDragUpdate(deltaX):
    position += deltaX * 0.9 / slotWidth
    pressure → 1

onDragEnd(velocityX):
    target = round(position + clamp(velocityX * 0.06, -0.45, 0.45))
    spring(
        mass = 1,
        stiffness = 420 * (1 - 0.55 * 0.22),
        dampingRatio = 0.85 - 0.55 * 0.08,
        initialVelocity = velocityX / slotWidth
    )
    pressure → 0
```

按住期间，`pressure` 从 0 在 120 ms 内升到 1，shader 的位移会增加，透镜尺寸也
会放大；`elasticity = 0.55` 同时控制回弹弹簧和放大幅度。减少动态效果或系统关闭
动画时，组件直接设置整数 slot，仍保留点击和拖动选择功能。

## 内容层与可访问性

滤镜只作用于材质背景，图标、文字和触控语义在 `Material` 子树中正常绘制。每个
导航项仍然是独立的 `Semantics(button: true, selected: ...)`，搜索仍是第四个独立
动作，不会被误报成第四个导航目的地。滑块的视觉放大只发生在绘制层，不改变 48 px
以上的触控区域，也不会把 Dock 的布局撑大。

## 降级策略

- 高对比度模式关闭 `BackdropFilter` 和 shader，使用实色背景与明确边线。
- shader 编译失败时退回 Flutter 的普通高斯模糊，交互和 Q 弹仍然可用。
- `MediaQuery.disableAnimations` 开启时不运行弹簧、按压放大和额外拉伸。
- 只保留一个共享 `FragmentProgram`，每个 Dock 实例仅创建自己的 uniforms；拖动时
  只更新 transform 和 painter，不做图片截图或 CPU 像素处理。

## 验证重点

修改后建议运行：

```bash
flutter test test/liquid_glass_dock_test.dart test/liquid_glass_optics_test.dart
dart analyze lib/widgets/liquid_glass_dock.dart
```

真机校准时重点观察三点：底座背景是否保持可读的高斯模糊、滑块经过高对比度图像
边缘时是否出现自然的 RGB 分离、松手后是否在一次短回弹内落到目标 tab。若设备 GPU
较慢，优先降低底座 `dockBackdropBlurSigma`；不要通过增加透明白色来伪造液态玻璃。
