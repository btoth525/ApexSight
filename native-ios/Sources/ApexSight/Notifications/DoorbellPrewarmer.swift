import Foundation

/// Best-effort warm of the doorbell live stream so the video is already flowing by the time you
/// answer — the go2rtc doorbell stream is an on-demand encoder that takes a beat to spin up. Fired
/// the instant the ring push arrives (before you answer), while the phone is still ringing.
///
/// Frigate 0.18 removed the `/api/go2rtc/api/...` HLS proxy this used to hit (a plain GET no longer
/// warms anything there), so warming now goes through the SAME proven WebRTC path the live view
/// uses (`/api/go2rtc/webrtc`) via `StreamPrewarmer` — a video-only consumer that keeps the encoder
/// hot for the ring window, then tears itself down. Fire-and-forget and fully guarded: if anything
/// is missing it simply no-ops and the answer cold-starts as before.
enum DoorbellPrewarmer {
    static func warm() {
        Task { @MainActor in
            StreamPrewarmer.shared.warmForCall(camera: "doorbell")
        }
    }
}
