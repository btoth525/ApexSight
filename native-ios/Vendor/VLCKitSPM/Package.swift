// swift-tools-version: 5.9
import PackageDescription

// LOCAL, offline mirror of `tylerjonesio/vlckit-spm` 3.6.0 (MobileVLCKit 3.6).
//
// Why local instead of the remote SPM URL: the upstream binary target is a 778 MB
// xcframework, and SwiftPM's binary-artifact downloader HANGS on it headless (0 B, no
// network, indefinitely — reproduced twice). We fetched the SAME artifact directly by URL
// and verified it byte-for-byte against upstream's published checksum
// (sha256 5da4747e001900bbb4153f58db2be4695096c9c2350aea00376ad67b39c053f6), then wired it
// in by `path:` so every build is offline and deterministic — no download, no stall.
//
// `VLCKit-all.xcframework` is git-ignored (2.1 GB). To restore it on a fresh machine see
// RESTORE.md next to this file. `import VLCKitSPM` re-exports MobileVLCKit on iOS.
let package = Package(
    name: "VLCKitSPM",
    platforms: [.iOS(.v12)],
    products: [
        .library(name: "VLCKitSPM", targets: ["VLCKitSPM"]),
    ],
    targets: [
        .binaryTarget(name: "VLCKit-all", path: "VLCKit-all.xcframework"),
        .target(
            name: "VLCKitSPM",
            dependencies: [
                .target(name: "VLCKit-all"),
            ],
            // MobileVLCKit is libvlc + all its codecs/demuxers; it resolves these system
            // libraries at link time. Copied verbatim from upstream's iOS linker settings —
            // omitting any one produces "Undefined symbol" at link.
            linkerSettings: [
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedLibrary("c++"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
