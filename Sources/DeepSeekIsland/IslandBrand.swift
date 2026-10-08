import AppKit
import SwiftUI

/// 应用标识：名称、版本号和应用内显示的 logo。
///
/// 图标（`AppIcon.icns`）由 `scripts/make-app-icon.swift` 从原图生成，
/// 打包脚本会把它放进 `Contents/Resources/` 并在 Info.plist 里指向它；
/// 这里的 `AppLogo.png` 是同一张图去掉四周留白后的版本，供界面内显示。
enum IslandBrand {
    static let name = "AIUsageIsland"

    /// 取打包时写进 Info.plist 的版本号；`swift run` 直接跑二进制时没有这个键。
    ///
    /// `versionOverride` 只给测试出图用：测试进程的 `Bundle.main` 是测试 runner，
    /// 读到的是 Xcode 自己的版本号（16.0），截图上的版本会不对。
    @MainActor static var versionOverride: String?

    @MainActor static var version: String {
        versionOverride
            ?? ApplicationVersion.version
            ?? "开发版"
    }

    /// App 内的 logo。
    ///
    /// 图放在 SwiftPM 资源包里，所以**打包成 .app 时必须把
    /// `AIUsageIsland_DeepSeekIsland.bundle` 一起放进 `Contents/Resources/`**，
    /// 只拷二进制的话这里会取不到图，界面就不显示 logo（其余功能不受影响）。
    /// `scripts/build-app.sh` 已经处理了这一步。
    ///
    /// 不用 SwiftPM 生成的 `Bundle.module`：它找不到资源包时直接 `fatalError`，
    /// 一个装饰性图标不该让整个应用起不来。
    static let logo: NSImage? = {
        let bundleName = "AIUsageIsland_DeepSeekIsland.bundle"
        if let image = IslandResources.bundle?.image(forResource: "AppLogo") { return image }
        NSLog("AIUsageIsland: 缺少资源包 %@，界面不显示 logo", bundleName)
        return nil
    }()

}

/// 界面内的 logo 标记。资源缺失时不占位：布局退回没有 logo 的样子，不会留一块空白。
struct IslandLogoMark: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    var size: CGFloat

    var body: some View {
        if let logo = IslandBrand.logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                // 深色底上原图的深蓝外框几乎和背景同色，加一圈极淡的描边把轮廓提出来。
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(palette.foreground.opacity(0.14), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
        }
    }
}
