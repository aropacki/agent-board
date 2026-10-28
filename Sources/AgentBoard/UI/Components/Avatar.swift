import AppKit
import SwiftUI

struct Avatar: View, Zoomed {
    @Environment(\.zoom) var zoom
    let login: String
    var size: CGFloat = 18

    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=64")) { phase in
            if let image = phase.image {
                image.resizable()
            } else {
                Circle().fill(T.text.opacity(0.1))
                    .overlay(Text(login.prefix(1).uppercased()).font(ui(size * 0.5, .semibold)).foregroundStyle(T.text2))
            }
        }
        .frame(width: z(size), height: z(size))
        .clipShape(Circle())
    }
}
