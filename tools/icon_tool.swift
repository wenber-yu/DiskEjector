#!/usr/bin/env swift
import CoreGraphics
import CoreText
// =============================================================
// icon_tool.swift — 图标生成工具（增强实现，当前未被脚本调用）
//
// 与 scripts/build_icon.sh 的关系：
//   build_icon.sh 是**当前生效**的图标生成入口（sips 缩放 + iconutil 合成），
//   由打包流程与开发者手动调用。
//   本文件是**能力更强的替代实现**，目前由 build_icon.sh 独立实现同类功能，
//   二者功能重叠但**尚未接线**——保留它是为了覆盖 sips 的能力缺口：
//
//   | 能力             | build_icon.sh (sips) | 本工具 (ImageIO) |
//   |------------------|----------------------|------------------|
//   | 常规 PNG/JPEG    | ✓                    | ✓                |
//   | palette PNG      | ✗ 读不了             | ✓                |
//   | 损坏/异常 PNG    | ✗ 直接失败           | ✓ 降级占位图     |
//   | 失败时保底       | ✗ 中断打包           | ✓ 生成占位图标   |
//
//   若日后遇到 sips 解不出的源图，可把 build_icon.sh 的缩放步骤替换为：
//     swift tools/icon_tool.swift <source_image> <iconset_dir>
//   再接 `iconutil -c icns` 合成即可，无需改动其它环节。
//
// 用法: swift tools/icon_tool.swift <source_image> <iconset_dir>
// 功能: 用 ImageIO 解码源图（png/jpeg/webp/tiff…，含 sips 读不了的
//       palette/损坏 PNG），重绘并输出 macOS iconset 全部 10 尺寸 PNG。
//       源图解码失败时自动生成 macOS 风格占位图标（圆角色块+"DE"），
//       保证 .app 始终带图标，永不因图标问题中断打包。
// 退出码: 0=成功, 1=输出错误, 2=参数错误
// =============================================================
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("用法: icon_tool.swift <source_image> <iconset_dir>\n".data(using: .utf8)!)
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
let iconsetDir = CommandLine.arguments[2]

// 尝试解码源图；失败则用占位图
var baseImage: CGImage?
if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
{
    baseImage = image
}
if baseImage == nil {
    FileHandle.standardError.write("提示: 源图不可解码（\(sourcePath)），改用占位图标。请替换为有效的 1024x1024 PNG。\n".data(using: .utf8)!)
}

// macOS iconset 规范的全部尺寸（文件名必须与 iconutil 约定一致）
let specs: [(Int, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
let colorSpace = CGColorSpaceCreateDeviceRGB()

// 画占位图标：蓝→深蓝渐变圆角方块 + 白色 "DE"
func drawPlaceholder(_ ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.22
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(rounded)
    ctx.clip()

    let top = CGColor(colorSpace: colorSpace, components: [0.23, 0.49, 0.95, 1.0])!
    let bottom = CGColor(colorSpace: colorSpace, components: [0.10, 0.24, 0.62, 1.0])!
    let grad = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: .zero, options: [])

    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, s * 0.42, nil)
    let white = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!
    let attrs =
        [
            kCTFontAttributeName as String: font,
            kCTForegroundColorAttributeName as String: white,
        ] as CFDictionary
    let attributed = CFAttributedStringCreate(nil, "DE" as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    ctx.textPosition = CGPoint(
        x: (s - bounds.width) / 2 - bounds.minX,
        y: (s - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, ctx)
}

for (size, name) in specs {
    let outURL = URL(fileURLWithPath: iconsetDir).appendingPathComponent("\(name).png")
    guard
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        FileHandle.standardError.write("无法创建画布 \(size)x\(size)\n".data(using: .utf8)!)
        exit(1)
    }
    if let image = baseImage {
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    } else {
        drawPlaceholder(ctx, size: size)
    }
    guard let outImage = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write("无法写入 \(name).png\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    CGImageDestinationFinalize(dest)
}

print("OK: 已生成 \(specs.count) 个尺寸 -> \(iconsetDir)")
