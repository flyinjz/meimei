// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Two folders of Swift: Core/ is the shared core (logic only: Foundation, no
// Apple-only frameworks, no UI), macOS/ is the macOS app. On macOS both compile
// into the app. On Windows and Linux only the core is built, as a library the
// Qt app calls through its C interface, plus a runner for the core's checks.

#if os(macOS)
// Raven Tunnel is a Go archive (wireguard-go + netstack) built from RavenTunnel/ into
// .build-tunnel by the build script; build it once before `swift build`:
//   (cd RavenTunnel && CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=13.0 go build -trimpath -buildmode=c-archive -o ../.build-tunnel/libraventunnel.a .)
let tunnelLib = Context.packageDirectory + "/.build-tunnel"

// The app target sits at the package root so it can take both macOS/ and Core/;
// everything else at the root (fonts, docs, the Go tunnel, local files) is excluded.
let appExcludes: [String] = {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: Context.packageDirectory)) ?? []
    let others = entries.filter { !$0.hasPrefix(".") && $0 != "macOS" && $0 != "Core" && $0 != "Package.swift" }
    let coreExtras = ["Core/include"].filter { FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + $0) }
    return others + coreExtras
}()

let package = Package(
    name: "MeimeiPlayer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "RavenTunnelC",
            path: "RavenTunnelC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MeimeiPlayer",
            dependencies: ["RavenTunnelC"],
            path: ".",
            exclude: appExcludes,
            sources: ["macOS", "Core"],
            linkerSettings: [
                .unsafeFlags(["-L" + tunnelLib, "-lraventunnel"]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
#else
let package = Package(
    name: "I2SCore",
    products: [
        .library(name: "I2SCore", type: .dynamic, targets: ["I2SCore"]),
        .executable(name: "I2SCoreCheck", targets: ["I2SCoreCheck"]),
    ],
    dependencies: [
        // Pinned: the version Windows resolved and tested (swift-asn1 1.7.4 comes with it).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "I2SCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Core",
            exclude: ["include"]
        ),
        .executableTarget(
            name: "I2SCoreCheck",
            dependencies: ["I2SCore"],
            path: "CoreCheck"
        ),
    ]
)
#endif
