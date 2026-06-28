import SwiftUI
import UIKit

/// A sharable payload (clip file or snapshot image) wrapped so it can drive `.sheet(item:)`.
/// `ShareLink` needs its content up front, but our clips download asynchronously, so we present
/// a UIActivityViewController once the item is ready instead.
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]

    init(url: URL) { items = [url] }
    init(image: UIImage) { items = [image] }
}

/// Thin SwiftUI wrapper over `UIActivityViewController` — AirDrop, Messages, Mail, Files, etc.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
