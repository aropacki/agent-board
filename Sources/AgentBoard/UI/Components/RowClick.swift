import AppKit

enum RowClick: Equatable { case diff, web, select }

/// ⌘ opens the web page in the background; ⇧, or any click while a selection exists, selects.
func rowClick(_ flags: NSEvent.ModifierFlags, selecting: Bool) -> RowClick {
    if flags.contains(.command) { return .web }
    return selecting || flags.contains(.shift) ? .select : .diff
}
