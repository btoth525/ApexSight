# Restoring `VLCKit-all.xcframework`

This local package wraps MobileVLCKit 3.6 for native RTSP + hardware H.265/H.264 decode
(the LAN live path — see `VLCLivePlayerView`). The binary is **git-ignored** (2.1 GB), so a
fresh clone needs it re-fetched. It is the exact artifact from `tylerjonesio/vlckit-spm`
`3.6.0`, verified against upstream's published SwiftPM checksum.

```bash
cd native-ios/Vendor/VLCKitSPM
curl -L -o VLCKit-all.xcframework.zip \
  https://github.com/tylerjonesio/vlckit-spm/releases/download/3.6.0/VLCKit-all.xcframework.zip

# MUST match — this is upstream's SwiftPM binaryTarget checksum:
echo "5da4747e001900bbb4153f58db2be4695096c9c2350aea00376ad67b39c053f6  VLCKit-all.xcframework.zip" \
  | shasum -a 256 -c -

unzip -q VLCKit-all.xcframework.zip        # -> VLCKit-all.xcframework/
rm VLCKit-all.xcframework.zip
cd ../../.. && cd native-ios && xcodegen generate
```

Do **not** re-point this at the remote SPM URL: SwiftPM's binary-artifact downloader hangs
on this 778 MB file when run headless (reproduced twice — 0 B, no network, no timeout).
Fetching by URL + `path:` binaryTarget is deliberate.

## After restoring: thin the device slice to arm64

The upstream device slice is a fat `arm64 armv7 armv7s` binary; App Store Connect rejects the
32-bit slices (ITMS unsupported-architecture). Strip it before archiving for upload:

```bash
DEV="VLCKit-all.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework/MobileVLCKit"
lipo "$DEV" -thin arm64 -output "$DEV.arm64" && mv "$DEV.arm64" "$DEV"
lipo -info "$DEV"   # -> arm64
```
