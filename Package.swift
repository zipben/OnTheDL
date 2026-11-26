// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OnTheDL",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OnTheDL", targets: ["OnTheDL"])],
    targets: [.executableTarget(name: "OnTheDL")]
)
