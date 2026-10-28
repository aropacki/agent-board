import AppKit
import SwiftUI

struct SectionNameKey: EnvironmentKey { static let defaultValue = "" }

/// Rows with the same id in this namespace move between sections instead of fading in place.
struct RowNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

/// Which window a view is in, so menus and right-click stay in the window they came from.
struct BoardSurfaceKey: EnvironmentKey { static let defaultValue = "panel" }

/// The scroll area a row sits in; a row only answers right-clicks inside its own area.
struct MenuViewportKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    var menuViewport: String {
        get { self[MenuViewportKey.self] }
        set { self[MenuViewportKey.self] = newValue }
    }
    var boardSurface: String {
        get { self[BoardSurfaceKey.self] }
        set { self[BoardSurfaceKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var sectionName: String {
        get { self[SectionNameKey.self] }
        set { self[SectionNameKey.self] = newValue }
    }
    var rowNamespace: Namespace.ID? {
        get { self[RowNamespaceKey.self] }
        set { self[RowNamespaceKey.self] = newValue }
    }
}
