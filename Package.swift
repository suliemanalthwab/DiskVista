// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DiskVista", platforms: [.macOS(.v14)], products: [.executable(name: "DiskVista", targets: ["DiskVista"])], targets: [.executableTarget(name: "DiskVista")], swiftLanguageModes: [.v5])
