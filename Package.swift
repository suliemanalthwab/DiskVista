// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskVista",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DiskVista", targets: ["DiskVista"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [.executableTarget(
        name: "DiskVista",
        dependencies: [.product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )],
    swiftLanguageModes: [.v5]
)
