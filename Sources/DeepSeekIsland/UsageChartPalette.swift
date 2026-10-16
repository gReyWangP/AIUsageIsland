import AppKit
import SwiftUI

/// Charts share one platform hue. Account variants change saturation only, so
/// their legend, stack and day details remain visibly part of the same family.
enum UsageChartPalette {
    static func theme(_ platform: UsagePlatform) -> Color {
        color(platform, saturationScale: 1)
    }

    static func account(_ account: AccountReference, among accounts: [AccountReference]) -> Color {
        let peers = Set(accounts.filter { $0.platform == account.platform }).sorted { $0.id < $1.id }
        guard peers.count > 1, let index = peers.firstIndex(of: account) else { return theme(account.platform) }
        let scale = 1 - 0.65 * Double(index) / Double(peers.count - 1)
        return color(account.platform, saturationScale: scale)
    }

    private static func color(_ platform: UsagePlatform, saturationScale: Double) -> Color {
        let base: NSColor = switch platform {
        case .deepSeek: NSColor(srgbRed: 77.0 / 255, green: 107.0 / 255, blue: 254.0 / 255, alpha: 1)
        case .chatGPT: NSColor(calibratedHue: 0.42, saturation: 0.78, brightness: 0.86, alpha: 1)
        case .zhipu: NSColor(calibratedHue: 0.78, saturation: 0.78, brightness: 0.86, alpha: 1)
        }
        let rgb = base.usingColorSpace(.sRGB) ?? base
        if saturationScale == 1 { return Color(nsColor: rgb) }
        return Color(hue: rgb.hueComponent, saturation: rgb.saturationComponent * saturationScale, brightness: rgb.brightnessComponent)
    }
}
