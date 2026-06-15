import Foundation

/// Converts a Frigate identifier like `front_porch` into a display string `Front Porch`.
func titleize(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
