// 从一张方形 logo 原图生成 macOS 应用图标与 App 内用的小尺寸 logo。
//
//   swift scripts/make-app-icon.swift <logo.png> <输出目录> [--padded]
//
// 输出：
//   <输出目录>/AppIcon.iconset/   —— iconutil 的输入
//   <输出目录>/AppIcon.icns       —— 应用图标（Info.plist 的 CFBundleIconFile）
//   <输出目录>/AppIcon-1024.png   —— 1024 主图（存档 / 商店用）
//   <输出目录>/AppLogo.png        —— 去掉四周留白，供界面内显示
//
// 默认**满幅**：logo 撑满整个 1024 画布。
//
// 这是实测结论，不是随手选的。本机 macOS 27 上，同一份 .app（只换 icns、各自独立
// bundle id 与全新路径）对比：留白版在访达/Dock 里是「一块浅灰圆角底板中间一个小图标」，
// 满幅版则和系统图标一样按 80% 画布正常显示。新系统会给没有铺满画布的图标垫底板。
// 原图内容区是 1091×1051，略微不方，所以满幅时按 3.8% 纵向拉伸对齐画布 ——
// 这个幅度肉眼看不出来，但换来的是不再被系统套底板。
//
// `--padded` 生成 Apple 经典栅格版（内容占 824/1024，四周留透明边），
// 这是 macOS 14/15 上的常规做法，适合要分发给旧系统的构建。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 参数

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        "用法：swift scripts/make-app-icon.swift <logo.png> <输出目录> [--padded]\n"
            .data(using: .utf8)!)
    exit(2)
}
let sourcePath = arguments[1]
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let padded = arguments.contains("--padded")

/// 画布边长；`--padded` 时内容占 824，否则铺满。
let canvasSide = 1024
let contentSide = padded ? 824 : 1024

// MARK: - 读入原图

guard let imageSource = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write("读不到图片：\(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

/// 取出不透明像素的外接矩形，用来裁掉原图四周的透明留白。
func opaqueBounds(of image: CGImage, threshold: UInt8) -> CGRect? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > threshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

guard let bounds = opaqueBounds(of: sourceImage, threshold: 4) else {
    FileHandle.standardError.write("原图整张都是透明的，无法生成图标\n".data(using: .utf8)!)
    exit(1)
}
// 多留 2 px，别把边缘的抗锯齿像素切掉。
let cropRect = bounds.insetBy(dx: -2, dy: -2)
    .intersection(CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
guard let cropped = sourceImage.cropping(to: cropRect) else {
    FileHandle.standardError.write("裁剪失败\n".data(using: .utf8)!)
    exit(1)
}

print("原图 \(sourceImage.width)×\(sourceImage.height)，内容区 "
      + "\(Int(cropRect.width))×\(Int(cropRect.height))")

// MARK: - 绘制

/// 把裁剪后的 logo 放进边长为 `side` 的画布，内容占 `contentRatio`，居中。
///
/// 满幅（`contentRatio == 1`）时按画布方形拉伸：原图内容区不方，
/// 等比贴合会在上下留出透明边，又会被系统套上灰底板。
func renderIcon(side: Int, contentRatio: Double, trim: Bool) -> CGImage? {
    guard let context = CGContext(data: nil,
                                  width: side,
                                  height: side,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    context.interpolationQuality = .high
    let box = trim ? Double(side) : Double(side) * contentRatio
    let aspect = Double(cropped.width) / Double(cropped.height)
    let fills = !trim && contentRatio >= 1
    var drawWidth = box
    var drawHeight = box
    if !fills {
        if aspect > 1 { drawHeight = box / aspect } else { drawWidth = box * aspect }
    }
    let rect = CGRect(x: (Double(side) - drawWidth) / 2,
                      y: (Double(side) - drawHeight) / 2,
                      width: drawWidth,
                      height: drawHeight)
    context.draw(cropped, in: rect)
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "make-app-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法写入 \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-app-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法写入 \(url.path)"])
    }
}

let contentRatio = Double(contentSide) / Double(canvasSide)
let fileManager = FileManager.default
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// iconutil 要求的文件名与像素尺寸。
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    // 每一档都直接从原图裁出来的那块降采样一次，避免逐级缩小的累积模糊。
    guard let image = renderIcon(side: variant.pixels, contentRatio: contentRatio, trim: false) else {
        FileHandle.standardError.write("生成 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

guard let master = renderIcon(side: canvasSide, contentRatio: contentRatio, trim: false) else {
    FileHandle.standardError.write("生成 1024 主图失败\n".data(using: .utf8)!)
    exit(1)
}
try write(master, to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))

// 界面内显示用：不留边距，撑满画布。
guard let inline = renderIcon(side: 256, contentRatio: contentRatio, trim: true) else {
    FileHandle.standardError.write("生成 AppLogo.png 失败\n".data(using: .utf8)!)
    exit(1)
}
try write(inline, to: outputDirectory.appendingPathComponent("AppLogo.png"))

// MARK: - icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path,
                      "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败（退出码 \(iconutil.terminationStatus)）\n"
        .data(using: .utf8)!)
    exit(1)
}

print("""
已生成：
  \(outputDirectory.appendingPathComponent("AppIcon.icns").path)
  \(outputDirectory.appendingPathComponent("AppIcon-1024.png").path)
  \(outputDirectory.appendingPathComponent("AppLogo.png").path)
  \(iconset.path)/（10 档 PNG）
""")
