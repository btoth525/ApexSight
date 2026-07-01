import Foundation

/// Words that have a canonical casing and must not be naively capitalized
/// (e.g. the carrier "ups" should read "UPS", not "Ups").
private let titleizeSpecialCasing: [String: String] = [
    "ups": "UPS", "usps": "USPS", "dhl": "DHL", "fedex": "FedEx",
    "ptz": "PTZ", "ai": "AI", "nvr": "NVR", "hd": "HD", "id": "ID"
]

/// Converts a Frigate identifier like `front_porch` into a display string `Front Porch`,
/// preserving canonical casing for known acronyms/brands (`ups` → `UPS`, `fedex` → `FedEx`).
func titleize(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { word -> String in
            if let special = titleizeSpecialCasing[word.lowercased()] { return special }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
}
