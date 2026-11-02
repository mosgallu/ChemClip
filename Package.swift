// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChemClip", platforms: [.macOS(.v13)],
    products: [.executable(name: "ChemClip", targets: ["ChemClip"]),
               .executable(name: "chemclip-tool", targets: ["ChemClipCLI"])],
    targets: [.target(name: "ChemClipCore"),
              .executableTarget(name: "ChemClip", dependencies: ["ChemClipCore"]),
              .executableTarget(name: "ChemClipCLI", dependencies: ["ChemClipCore"]),
              .testTarget(name: "ChemClipCoreTests", dependencies: ["ChemClipCore"])])
