// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageIsland",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIUsageIsland", targets: ["DeepSeekIsland"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        // Sources 里的 Resources 只有界面内显示的 AppLogo.png；应用图标 AppIcon.icns
        // 放在仓库根的 Resources/ 下，由 scripts/build-app.sh 装进 .app 包，不参与编译。
        .executableTarget(name: "DeepSeekIsland",
                          dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DeepSeekIslandTests", dependencies: ["DeepSeekIsland"])
    ]
)
