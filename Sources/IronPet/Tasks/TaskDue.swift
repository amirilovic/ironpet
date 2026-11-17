import Foundation

/// What is remembered about one task's due reminder, in `task_due_marks`: the due date it was announced for and, after
/// Snooze, when to announce it again.
struct TaskDueMark: Equatable {
    var due: Date
    /// nil: announced, and not again for this due date.
    var snoozedUntil: Date?
}

/// When an open task's due date calls for a nudge. The clock and calendar are passed in so tests set them.
enum TaskDue {
    enum Kind: Equatable {
        /// A plain date that is today.
        case today
        /// A time that passed less than an hour ago.
        case now
        case overdue
    }

    /// A due date at local midnight came from a plain date (`2026-11-20`) and lasts the whole day.
    static func isAllDay(_ due: Date, calendar: Calendar) -> Bool {
        calendar.dateComponents([.hour, .minute, .second], from: due) == DateComponents(hour: 0, minute: 0, second: 0)
    }

    /// A time has come once it has passed; a plain date is stored as its local midnight, so it comes when its day starts.
    static func hasCome(_ task: TaskItem, now: Date) -> Bool {
        guard let due = task.due, task.status != .done else { return false }
        return due <= now
    }

    /// Open tasks whose due date has come and that were not announced for that date, or whose snooze has ended, soonest
    /// due first. A mark for an earlier due date does not count, so moving the date announces the task again.
    static func pending(_ tasks: [TaskItem], marks: [String: TaskDueMark], now: Date) -> [TaskItem] {
        tasks.filter { task in
            guard hasCome(task, now: now), let due = task.due else { return false }
            guard let mark = marks[task.id], mark.due == due else { return true }
            return mark.snoozedUntil.map { $0 <= now } ?? false
        }
        .sorted { ($0.due!, $0.id) < ($1.due!, $1.id) }
    }

    static func kind(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Kind {
        guard let due = task.due else { return .overdue }
        if isAllDay(due, calendar: calendar) { return calendar.isDate(due, inSameDayAs: now) ? .today : .overdue }
        return now.timeIntervalSince(due) < 3600 ? .now : .overdue
    }

    /// Plain dates snooze to 9:00 tomorrow, since an hour later the day has not changed; anything with a time, an hour.
    static func snoozeEnd(for tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> Date {
        guard snoozesToTomorrow(tasks, calendar: calendar),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) else {
            return now.addingTimeInterval(3600)
        }
        return morning
    }

    static func snoozesToTomorrow(_ tasks: [TaskItem], calendar: Calendar = .current) -> Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.due.map { isAllDay($0, calendar: calendar) } ?? false }
    }
}
