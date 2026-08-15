import Foundation
import Testing
@testable import ApexSightNative

/// Regression guards for the client behaviour that took the Frigate server down.
///
/// On 2026-08-14 the server's API went fully unresponsive for ~7 hours. The cause was not a
/// Frigate bug in isolation: Frigate answers previews, snapshots and exports by spawning an ffmpeg
/// and streaming its pipe, and when a client abandons one of those requests nobody drains the
/// pipe — ffmpeg blocks forever holding an API worker. Forty of them leaked, at roughly one per 22
/// minutes, until the worker pool was exhausted. nginx logged `499` (client closed) at
/// `request_time="125.0"` against this app's own user agents.
///
/// Two client defects made that possible, and these tests pin both:
///  • **No total time cap.** `URLRequest.timeoutInterval` is an IDLE timeout — a trickling pipe
///    resets it indefinitely — and every extension rode `URLSession.shared`, whose
///    `timeoutIntervalForResource` is seven days.
///  • **No pacing.** The camera wall polled on a fixed tick with no failure path, so a server that
///    was already failing to answer got the same request rate regardless.
@Suite("Server load")
struct ServerLoadPolicyTests {

    // MARK: - Total time caps

    @Test("Every Frigate session bounds total transfer time, not just idle time")
    func sessionsCapTotalTime() {
        for session in [FrigateClient.apiSession,
                        FrigateClient.downloadSession,
                        BoundedSession.notificationMedia,
                        BoundedSession.widget] {
            let total = session.configuration.timeoutIntervalForResource
            // URLSession.shared's default is 7 days (604800). Anything near it means an abandoned
            // request can hold a server-side ffmpeg open for as long as the server will trickle.
            #expect(total > 0)
            #expect(total <= 300, "resource timeout \(total)s is long enough to leak an export")
        }
    }

    @Test("A clip export can no longer be held open for an hour")
    func downloadSessionIsBounded() {
        #expect(FrigateClient.downloadSession.configuration.timeoutIntervalForResource <= 180)
        // Parking a request through an outage keeps the server's end of it open too.
        #expect(FrigateClient.downloadSession.configuration.waitsForConnectivity == false)
    }

    @Test("Concurrency is capped so a nine-camera wall can't arrive as nine simultaneous requests")
    func connectionsAreCapped() {
        #expect(FrigateClient.apiSession.configuration.httpMaximumConnectionsPerHost <= 3)
        #expect(BoundedSession.notificationMedia.configuration.httpMaximumConnectionsPerHost <= 3)
        #expect(BoundedSession.widget.configuration.httpMaximumConnectionsPerHost <= 3)
    }

    @Test("The notification extension gives up well inside its ~30s budget")
    func notificationMediaFitsExtensionBudget() {
        // Being killed mid-download is precisely the abandoned request that orphans an ffmpeg,
        // so the cap has to bite before iOS kills the extension.
        #expect(BoundedSession.notificationMedia.configuration.timeoutIntervalForResource < 25)
    }

    // MARK: - Wall pacing

    @Test("A fast server keeps the wall's natural rhythm")
    func fastServerKeepsBaseCadence() {
        #expect(SnapshotPollPolicy.next(lastDuration: 0.2, consecutiveFailures: 0)
                == .wait(SnapshotPollPolicy.base))
    }

    @Test("A slow answer stretches the next request instead of ignoring how long it took")
    func slowServerStretchesCadence() {
        #expect(SnapshotPollPolicy.next(lastDuration: 5, consecutiveFailures: 0) == .wait(10))
    }

    @Test("Cadence never exceeds the cap, so a recovered server is picked up within a minute")
    func cadenceIsCapped() {
        #expect(SnapshotPollPolicy.next(lastDuration: 600, consecutiveFailures: 0)
                == .wait(SnapshotPollPolicy.maxDelay))
    }

    @Test("Failures back off exponentially rather than re-firing at the same rate")
    func failuresBackOff() {
        #expect(SnapshotPollPolicy.next(lastDuration: nil, consecutiveFailures: 1) == .wait(3))
        #expect(SnapshotPollPolicy.next(lastDuration: nil, consecutiveFailures: 2) == .wait(6))
        #expect(SnapshotPollPolicy.next(lastDuration: nil, consecutiveFailures: 3) == .wait(12))
        #expect(SnapshotPollPolicy.next(lastDuration: nil, consecutiveFailures: 4) == .wait(24))
    }

    @Test("Sustained failure drops to a heartbeat — but never stops entirely")
    func sustainedFailureHeartbeats() {
        let next = SnapshotPollPolicy.next(lastDuration: nil,
                                           consecutiveFailures: SnapshotPollPolicy.failuresBeforeHeartbeat)
        #expect(next == .heartbeat(SnapshotPollPolicy.maxDelay))
        // A wall that silently stopped updating until the user thought to interact would be a
        // worse failure than one quietly checking once a minute.
        #expect(next.delay <= 60)
    }

    @Test("A success clears the backoff immediately")
    func successResetsBackoff() {
        #expect(SnapshotPollPolicy.next(lastDuration: 0.1, consecutiveFailures: 0)
                == .wait(SnapshotPollPolicy.base))
    }

    @Test("A rebuilt tile serves out the rest of the interval instead of fetching instantly")
    func restartResumesTheRhythm() {
        // The failure this prevents: `.task` is rebuilt for every notification banner, camera list
        // reload or view re-key, and a rebuilt task fetches immediately. Nine tiles doing that
        // together is a burst — during an alert storm, exactly when the server is loaded.
        #expect(SnapshotPollPolicy.initialDelay(sinceLastFetch: 0) == SnapshotPollPolicy.base)
        #expect(SnapshotPollPolicy.initialDelay(sinceLastFetch: 1) == SnapshotPollPolicy.base - 1)
    }

    @Test("A tile that has waited long enough — or has never fetched — paints immediately")
    func restartDoesNotStallAFreshTile() {
        // A genuinely new tile loading the wall is not a burst, and must not be delayed.
        #expect(SnapshotPollPolicy.initialDelay(sinceLastFetch: nil) == 0)
        #expect(SnapshotPollPolicy.initialDelay(sinceLastFetch: 30) == 0)
        // A clock that jumped backwards must not produce a wait longer than the interval itself.
        #expect(SnapshotPollPolicy.initialDelay(sinceLastFetch: -10) == 0)
    }

    @Test("A missing or nonsense duration falls back to the base rhythm, never to zero")
    func durationFailsQuiet() {
        #expect(SnapshotPollPolicy.next(lastDuration: nil, consecutiveFailures: 0) == .wait(3))
        #expect(SnapshotPollPolicy.next(lastDuration: -5, consecutiveFailures: 0) == .wait(3))
        #expect(SnapshotPollPolicy.next(lastDuration: .infinity, consecutiveFailures: 0) == .wait(3))
    }

    // MARK: - Notification media reuse

    @Test("Stills are reused across the two pushes for one alert")
    func stillsAreCacheable() {
        #expect(NotificationMediaCache.isCacheable(URL(string: "https://f.example/api/events/1/snapshot.jpg")!))
    }

    @Test("GIFs are never reused — the follow-up push exists to carry the finished animation")
    func gifsAreNotCacheable() {
        #expect(!NotificationMediaCache.isCacheable(URL(string: "https://f.example/api/events/1/preview.gif")!))
    }

    @Test("Two URLs can never collide onto one another's picture")
    func cacheKeysAreDistinct() {
        let a = URL(string: "https://f.example/api/events/1/snapshot.jpg")!
        let b = URL(string: "https://f.example/api/events/2/snapshot.jpg")!
        let cropped = URL(string: "https://f.example/api/events/1/snapshot.jpg?bbox=1&crop=1")!
        #expect(NotificationMediaCache.fileName(for: a) != NotificationMediaCache.fileName(for: b))
        // The cropped variant is a different picture of the same event — it must not reuse the
        // uncropped file just because the event id matches.
        #expect(NotificationMediaCache.fileName(for: a) != NotificationMediaCache.fileName(for: cropped))
        #expect(NotificationMediaCache.fileName(for: a) == NotificationMediaCache.fileName(for: a))
        #expect(NotificationMediaCache.fileName(for: a).hasSuffix(".jpg"))
    }
}
