// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FITHealthCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FITHealthCore", targets: ["FITHealthCore"])],
    targets: [
        .target(name: "FITHealthCore", path: "FITHealth/Core"),
        .testTarget(name: "FITHealthCoreTests", dependencies: ["FITHealthCore"], path: "FITHealthTests")
    ]
)
