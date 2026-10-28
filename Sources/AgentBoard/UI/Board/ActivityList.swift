import AppKit
import SwiftUI

/// Every event the ticker has shown, newest first, grouped by day. Rows that arrived since the
/// last look stay bright; older ones recede.
struct ActivityList: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    @State private var since: Date?

    var body: some View {
        let days = Dictionary(grouping: board.activity) { Calendar.current.startOfDay(for: $0.at) }
        LazyVStack(alignment: .leading, spacing: z(2)) {
            if board.activity.isEmpty {
                VStack(spacing: z(4)) {
                    Text("No activity yet").font(ui(13, .medium)).foregroundStyle(T.text2)
                    Text("Finished chats, reviews, and CI changes collect here.").font(ui(12)).foregroundStyle(T.text3)
                }
                .frame(maxWidth: .infinity).padding(.top, z(60))
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Text(dayLabel(day)).font(ui(11.5, .medium)).foregroundStyle(T.text3)
                    .padding(.horizontal, z(8)).padding(.top, z(10)).padding(.bottom, z(2))
                ForEach((days[day] ?? []).sorted { $0.at > $1.at }) { event in
                    row(event, fresh: event.at > (since ?? .distantFuture))
                }
            }
        }
        .onAppear {
            since = board.activitySeenAt
            board.markActivitySeen()
        }
    }

    func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    func row(_ event: TickerEvent, fresh: Bool) -> some View {
        HStack(alignment: .top, spacing: z(8)) {
            Image(systemName: event.icon).font(.system(size: z(11)))
                .foregroundStyle(event.color.opacity(fresh ? 1 : 0.6))
                .frame(width: z(14), height: z(17))
            VStack(alignment: .leading, spacing: z(2)) {
                Text(event.subject).font(ui(13, fresh ? .medium : .regular)).foregroundStyle(fresh ? T.text : T.text2).lineLimit(2)
                Text(event.label).font(ui(11.5)).foregroundStyle(T.text3)
            }
            Spacer(minLength: z(4))
            OnTitleBaseline(text: event.at.formatted(date: .omitted, time: .shortened), titleFont: ui(13), font: digits(11.5))
        }
        .padding(.horizontal, z(8)).padding(.vertical, z(6))
        .rowSurface(interactive: event.target != nil)
        .onTapGesture { board.openActivity(event, surface: surface) }
        .help(event.target == nil ? event.text : "Open")
        .menuTarget("activity:\(event.id.uuidString)")
    }
}
