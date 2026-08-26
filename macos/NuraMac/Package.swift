// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Xcode's default Debug configuration should link the symbol-rich Rust build.
// Release packaging overrides this with NURA_RUST_LIB_DIR=target/release.
let rustLibraryDirectory = ProcessInfo.processInfo.environment["NURA_RUST_LIB_DIR"] ?? "../../target/debug"

let package = Package(
    name: "NuraMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NuraMac", targets: ["NuraMac"])],
    targets: [
        .executableTarget(
            name: "NuraMac",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLibraryDirectory)", "-lnura_ffi"]),
                .linkedFramework("AppKit"),
                .linkedFramework("OpenGL"),
            ]
        ),
    ]
)
