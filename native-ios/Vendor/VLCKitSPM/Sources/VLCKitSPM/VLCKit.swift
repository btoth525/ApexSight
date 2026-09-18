// Re-export shim (verbatim from upstream tylerjonesio/vlckit-spm). Lets call sites write
// `import VLCKitSPM` while the actual symbols come from the platform framework inside the
// xcframework — MobileVLCKit on iOS. This package is iOS-only, so the tvOS/macOS branches
// upstream carries are dropped.
#if os(iOS) && !targetEnvironment(macCatalyst)
@_exported import MobileVLCKit
#endif
