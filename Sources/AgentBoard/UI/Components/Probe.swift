import AppKit

/// Test-only record of what each live card row last drew. Off in the app.
enum Probe {
    static var on = false
    static var rows: [UUID: (id: String, section: String, dot: String, reasons: [String])] = [:]
}
