import Foundation

/// 已打包应用只读取自己 Contents/Resources 下的资源，不探测开发机的编译路径。
enum IslandResources {
    static let bundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            return packagedBundle(in: .main)
        }
        // swift run / swift test 没有 .app 容器，才使用 SwiftPM 开发资源。
        return Bundle.module
    }()

    static func packagedBundle(in appBundle: Bundle) -> Bundle? {
        guard let resources = appBundle.resourceURL else { return nil }
        return Bundle(url: resources.appendingPathComponent("AIUsageIsland_DeepSeekIsland.bundle"))
    }
}
