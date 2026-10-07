# LumaCaption 品牌图标

- 当前图标：`LumaCaption-liquid-glass.png`，1254 × 1254，RGBA，透明外缘。
- macOS 图标：`LumaCaption.icns`，包含 16、32、64、128、256、512、1024 像素表示。
- 概念：字幕气泡、三行字幕与中间声波；平面正视构图、蓝色与冰白色、克制的玻璃边缘。
- 使用内置 `image_gen` 生成，并做一次降低厚重高光的表面修订；未使用 API CLI。
- 仅对生成图进行标准尺寸缩放与 ICNS 打包，没有修改图像主体。构建脚本将 ICNS 放入应用 Resources，Info.plist 和边栏显式使用它。

## 初始生成提示

```text
Use case: logo-brand
Asset type: production macOS app icon for LumaCaption, a live caption and translation app.
Primary request: design a flat Liquid Glass logo with a clean instantly legible silhouette. One simple pale luminous caption bubble containing three short horizontal caption strokes; its small lower-left tail subtly resembles an L. Combine the middle stroke with a restrained audio-wave rhythm without introducing extra symbols. Flat frontal geometry, no perspective.
Composition: one centered icon, large bold symbol filling roughly 65 percent of a rounded square tile; transparent pixels outside the tile; visually even 8 percent external padding. The full square canvas is 1024 by 1024. No lettering, no wordmark.
Style: minimal flat translucent glass, crisp edges, just a thin soft rim highlight, restrained single-layer translucency; a quiet cool blue tint compatible with the app's existing macOS accent color. White-to-ice-blue symbol against a clear mid blue tile, subtle luminance gradient. It must remain recognisable at 32 pixels.
Avoid: photorealistic chrome, heavy 3D bevels, lens flares, rainbow ribbons, layered blobs, excessive reflections, floor shadows, tiny details, Apple logo, microphone pictogram, flags, extra panels, watermarks, text.
```

## 最终表面修订提示

```text
Refine this LumaCaption app icon into a flatter Liquid Glass logo. Keep the exact centered caption-bubble and waveform geometry, cool blue palette, rounded-square tile and overall composition. Change only the surface treatment: reduce the pronounced bevel and bloom to a thin subtle edge highlight, with quiet flat translucent fills. Clean perfectly smooth outer silhouette, absolutely no stray glow pixels or fragments beyond the icon. Keep transparent external margin on all four sides. No lettering, no added symbols, no 3D depth or perspective. Production macOS icon, crisp at small sizes.
```

