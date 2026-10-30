import AppKit
import SwiftUI

struct Avatar: View, Zoomed {
    @Environment(\.zoom) var zoom
    let login: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = Avatars.shared.image(login) {
                Image(nsImage: image).resizable()
            } else {
                Circle().fill(T.text.opacity(0.1))
                    .overlay(Text(login.prefix(1).uppercased()).font(ui(size * 0.5, .semibold)).foregroundStyle(T.text2))
            }
        }
        .frame(width: z(size), height: z(size))
        .clipShape(Circle())
    }
}

/// Each login's picture, fetched once per launch. A view that mounts an avatar it has already shown draws it in the
/// same frame, where an `AsyncImage` would fetch, decode, and re-render the row a few frames later.
@MainActor @Observable final class Avatars {
    static let shared = Avatars()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func image(_ login: String) -> NSImage? {
        if let image = images[login] { return image }
        load(login)
        return nil
    }

    private func load(_ login: String) {
        guard !isBench, requested.insert(login).inserted,
              let url = URL(string: "https://github.com/\(login).png?size=64") else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                images[login] = image
            } else {
                requested.remove(login)
            }
        }
    }
}
