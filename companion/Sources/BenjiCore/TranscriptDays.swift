import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// The transcript's date lines and its scroll-to-latest button (D-133). Pure decisions only; the
// app draws them.

/// One item of the transcript: a row, or a thin date line before the first row of a new day.
public enum TranscriptItem: Equatable, Identifiable, Sendable {
    case dateLine(id: String, title: String)
    case row(PanelRow)

    public var id: String {
        switch self {
        case .dateLine(let id, _): return id
        case .row(let row): return row.id.uuidString
        }
    }
}

public enum TranscriptDays {
    /// The rows with a date line wherever one calendar day gives way to another. A conversation
    /// held on one day has none; once it spans days, its first day is named too, so every turn
    /// sits under its day. Rows without a time (restored from a file saved before lines carried
    /// one) are older than any timed row, so the first timed row after them starts a new day.
    public static func items(_ rows: [PanelRow], now: Date, calendar: Calendar = .current,
                             locale: Locale = .current) -> [TranscriptItem] {
        enum Before { case nothing, untimed, day(Date) }
        var before = Before.nothing
        var items: [TranscriptItem] = []
        var firstTimed: (index: Int, row: PanelRow)?
        var changed = false
        for row in rows {
            guard let at = row.line.at else {
                if case .nothing = before { before = .untimed }
                items.append(.row(row))
                continue
            }
            let day = calendar.startOfDay(for: at)
            switch before {
            case .nothing:
                firstTimed = (items.count, row)
            case .untimed:
                changed = true
                items.append(line(for: row, day: day, now: now, calendar: calendar, locale: locale))
            case .day(let previous) where previous != day:
                changed = true
                items.append(line(for: row, day: day, now: now, calendar: calendar, locale: locale))
            case .day:
                break
            }
            before = .day(day)
            items.append(.row(row))
        }
        if changed, let first = firstTimed, let at = first.row.line.at {
            items.insert(line(for: first.row, day: calendar.startOfDay(for: at), now: now, calendar: calendar,
                              locale: locale), at: first.index)
        }
        return items
    }

    private static func line(for row: PanelRow, day: Date, now: Date, calendar: Calendar,
                             locale: Locale) -> TranscriptItem {
        .dateLine(id: "day-" + row.id.uuidString, title: title(day, now: now, calendar: calendar, locale: locale))
    }

    /// "Today", "Yesterday", else a short weekday, day and month ("Thu 30 Oct" in British
    /// English), with the year once it isn't this year's.
    public static func title(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
            return f.string(from: date)
        }
    }
}

/// The transcript's scroll-to-latest button: shown only while scrolled up by more than about a row.
public enum ScrollToLatest {
    /// About one transcript row (a body line and the gap under it).
    public static let threshold: CGFloat = 28

    /// `distance`: how far the transcript's end sits below the visible bottom edge.
    public static func shows(distanceFromBottom distance: CGFloat) -> Bool {
        distance > threshold
    }
}
