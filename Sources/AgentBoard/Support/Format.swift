import AppKit

func shortAge(from: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(from)))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func checkDuration(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds.rounded()))
    if t < 60 { return "\(t)s" }
    if t < 3600 { return "\(t / 60)m " + String(format: "%02ds", t % 60) }
    return "\(t / 3600)h " + String(format: "%02dm", t % 3600 / 60)
}

func relativeTime(_ t: Double, _ now: Date) -> String {
    let s = now.timeIntervalSince1970 - t
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d"
}
