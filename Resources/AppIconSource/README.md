# App 图标源文件

图标由两层矢量组成，分层渲染后再合成阴影：

- `body.svg`：圆角底板（深蓝 → 靛紫渐变）与剩余额度凹槽，平贴、无浮起阴影
- `glyphs.svg`：`>` 提示符、已用额度条（占 0.618）与闪光星，统一青色 → 淡紫渐变
- `compose.swift`：用 CoreGraphics 给底板加整体投影、给符号加浮起阴影，输出指定尺寸 PNG

构图基于黄金分割：左右留白与内容宽 1 : φ³（132 : 560），额度条已用 / 剩余 = φ : 1，内容组上下居中。

重新生成（需先把两个 SVG 渲染为 1024px PNG）：

```bash
swiftc compose.swift -o compose
./compose body.png glyphs.png ../Assets.xcassets/AppIcon.appiconset/icon_1024.png 1024
```

其余尺寸（16 / 32 / 64 / 128 / 256 / 512）同理。
