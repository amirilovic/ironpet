import XCTest
@testable import IronPet

/// Shared fixtures: Tuesday 2026-11-17 in UTC, after the Monday the automation tests use.
private enum BriefFixture {
    static let calendar = AutomationTestClock.calendar
    static func tuesday(hour: Int, minute: Int = 0) -> Date { AutomationTestClock.monday(plus: 1, hour: hour, minute: minute) }
    static var startOfTuesday: Date { calendar.startOfDay(for: tuesday(hour: 12)) }

    static func task(_ id: String, _ status: TaskStatus = .backlog, due: Date? = nil, waitingOn: String? = nil,
                     updated: Date = tuesday(hour: 7), closed: Date? = nil) -> TaskItem {
        TaskItem(id: id, title: "Task \(id)", notes: "", status: status, source: .chat, due: due, links: [],
                 created: tuesday(hour: 6), updated: updated, closed: closed, waitingOn: waitingOn)
    }

    static func signal(_ id: String, _ label: String, mood: PetMood = .needsInput, minutes: Double = 10) -> Signal {
        Signal(id: id, title: "PR \(id)", subtitle: "you/repo #\(id)", url: URL(string: "https://example.com/\(id)"),
               date: tuesday(hour: 8).addingTimeInterval(-minutes * 60), label: label, symbol: "eye.fill", mood: mood, ask: nil)
    }

    static func session(_ id: String, _ status: AgentStatus, at: Date = tuesday(hour: 8)) -> AgentSession {
        var s = AgentSession(id: id, source: .claude, status: status, prompt: "Do \(id)")
        s.origin = SessionOrigin(workspace: "/Users/you/code/\(id)", termProgram: nil, itermSessionID: nil)
        s.updatedAt = at
        s.lastResponse = "Summary \(id)."
        return s
    }

    static func turn(_ ref: String, _ kind: BriefActivity.Kind, at: Date) -> BriefActivity {
        BriefActivity(kind: kind, at: at, ref: ref, title: "repo-\(ref)", detail: "did \(ref)", agent: "Claude Code",
                      workspace: "/w/\(ref)", bundleID: "com.example.app")
    }
}

final class BriefBuilderTests: XCTestCase {
    private typealias F = BriefFixture

    private func section(_ brief: Brief, _ id: String) -> [Brief.Item] { brief.sections.first { $0.id == id }?.items ?? [] }

    func testTheBriefListsDueNeedsAlertsMeetingsAndWaitingAgents() {
        let input = BriefInput(
            now: F.tuesday(hour: 9), calendar: F.calendar,
            tasks: [F.task("late", due: F.startOfTuesday.addingTimeInterval(-86_400)), F.task("today", due: F.startOfTuesday),
                    F.task("later", due: F.startOfTuesday.addingTimeInterval(3 * 86_400)), F.task("ask", .needsYou),
                    F.task("theirs", .needsYou, waitingOn: "Ana"), F.task("done", .done, due: F.startOfTuesday)],
            sessions: [F.session("wait", .needsInput), F.session("broke", .failed), F.session("ok", .done), F.session("run", .running)],
            alerts: [F.signal("1", "Changes requested"), F.signal("2", "Review requested"), F.signal("3", "CI failed"),
                     F.signal("4", "Approved", mood: .done)],
            meetings: [BriefMeeting(id: "m", date: F.tuesday(hour: -9), preview: "Planning", openItems: ["Send notes", "Task ask."])])
        let brief = BriefBuilder.brief(input)

        XCTAssertEqual(section(brief, "due").map(\.target), [.task("late"), .task("today")])
        XCTAssertEqual(section(brief, "needs").map(\.target), [.task("ask")])
        XCTAssertEqual(section(brief, "alerts").map(\.id), ["alert:2", "alert:3", "alert:1"])
        // An action item that matches an open task opens the task; the others open the meeting.
        XCTAssertEqual(section(brief, "meetings").map(\.target), [.meeting("m"), .task("ask")])
        XCTAssertEqual(section(brief, "agents").map(\.title), ["wait", "broke"])
        XCTAssertEqual(brief.lines, ["1 task due today, 1 overdue", "1 task needs you",
                                     "1 review requested, 1 CI failed +1 more", "2 open action items from meetings"])
    }

    func testAMeetingItemThatIsAlreadyDoneIsLeftOut() {
        let input = BriefInput(now: F.tuesday(hour: 9), calendar: F.calendar, tasks: [F.task("x", .done)],
                               meetings: [BriefMeeting(id: "m", date: F.tuesday(hour: -2), preview: "", openItems: ["task x"])])
        XCTAssertTrue(BriefBuilder.brief(input).isEmpty)
    }

    func testMondaysBriefReachesBackToFridayOnWeekdays() {
        let monday = AutomationTestClock.monday(hour: 9)
        let since = BriefBuilder.meetingsSince(weekdays: AutomationDefaults.weekdays, now: monday, calendar: F.calendar)
        XCTAssertEqual(since, AutomationTestClock.monday(plus: -3, hour: 0))
        XCTAssertEqual(BriefBuilder.meetingsSince(weekdays: nil, now: monday, calendar: F.calendar), AutomationTestClock.monday(plus: -1, hour: 0))
        let friday = BriefMeeting(id: "fri", date: AutomationTestClock.monday(plus: -3, hour: 14), preview: "", openItems: ["Call Sam"])
        let thursday = BriefMeeting(id: "thu", date: AutomationTestClock.monday(plus: -4, hour: 14), preview: "", openItems: ["Old"])
        let brief = BriefBuilder.brief(BriefInput(now: monday, calendar: F.calendar, meetings: [friday, thursday]), meetingsSince: since)
        XCTAssertEqual(section(brief, "meetings").map(\.title), ["Call Sam"])
    }

    func testTheRecapListsTodayOnlyAndAlwaysEndsWithStillOpen() {
        let input = BriefInput(
            now: F.tuesday(hour: 18), calendar: F.calendar,
            tasks: [F.task("closed", .done, closed: F.tuesday(hour: 11)), F.task("old", .done, closed: F.tuesday(hour: -5)),
                    F.task("ask", .needsYou), F.task("doing", .inProgress), F.task("later")],
            sessions: [F.session("wait", .needsInput)],
            alerts: [F.signal("1", "CI failed"), F.signal("2", "Approved", mood: .done)],
            meetings: [BriefMeeting(id: "sync", date: F.tuesday(hour: 10), preview: "Weekly sync", openItems: []),
                       BriefMeeting(id: "yday", date: F.tuesday(hour: -6), preview: "Yesterday", openItems: [])],
            activity: [F.turn("a", .sessionDone, at: F.tuesday(hour: 10)), F.turn("b", .sessionDone, at: F.tuesday(hour: 12)),
                       F.turn("c", .sessionFailed, at: F.tuesday(hour: 13)), F.turn("y", .sessionDone, at: F.tuesday(hour: -1)),
                       BriefActivity(kind: .alertResolved, at: F.tuesday(hour: 14), ref: "9", title: "PR 9", detail: "CI failed",
                                     agent: nil, workspace: nil, bundleID: nil)])
        let recap = BriefBuilder.recap(input)
        XCTAssertEqual(section(recap, "agents").map(\.title), ["repo-c", "repo-b", "repo-a"])
        XCTAssertEqual(section(recap, "agents").first?.target, .session(id: "c", workspace: "/w/c", bundleID: "com.example.app"))
        XCTAssertEqual(section(recap, "closed").map(\.target), [.task("closed")])
        XCTAssertEqual(section(recap, "resolved").map(\.target), [.alert(id: "9", url: nil)])
        XCTAssertEqual(section(recap, "meetings").map(\.target), [.meeting("sync")])
        XCTAssertEqual(section(recap, "open").map(\.id), ["open:ask", "open:doing", "alert:1", "session:wait"])
        XCTAssertEqual(recap.lines, ["Agents finished 2 turns, 1 failed", "1 task closed", "1 alert resolved",
                                     "Still open: 2 tasks, 1 alert, 1 agent"])
    }

    func testAnEmptyDayIsEmpty() {
        let input = BriefInput(now: F.tuesday(hour: 18), calendar: F.calendar, tasks: [F.task("later")])
        XCTAssertTrue(BriefBuilder.brief(input).isEmpty)
        XCTAssertTrue(BriefBuilder.recap(input).isEmpty)
        XCTAssertEqual(BriefBuilder.recap(input).lines, [])
    }

    func testAlertLineNamesAtMostTwoLabels() {
        XCTAssertEqual(BriefBuilder.alertLine([F.signal("1", "Review requested"), F.signal("2", "Review requested")]), "2 review requested")
        XCTAssertEqual(BriefBuilder.alertLine([F.signal("1", "CI failed")]), "1 CI failed")
        XCTAssertEqual(BriefBuilder.alertLine([F.signal("1", "Sentry"), F.signal("2", "CI failed"), F.signal("3", "Review requested"),
                                               F.signal("4", "Sentry")]), "1 review requested, 1 CI failed +2 more")
    }

    func testFinishedSessionsBecomeRecapActivityUntilTheActivityLogLands() {
        let window = DateInterval(start: F.startOfTuesday, end: F.tuesday(hour: 18))
        let events = BriefSource.finishedSessions([F.session("ok", .done, at: F.tuesday(hour: 9)), F.session("bad", .failed, at: F.tuesday(hour: 10)),
                                                   F.session("y", .done, at: F.tuesday(hour: -2)), F.session("wait", .needsInput)], in: window)
        XCTAssertEqual(events.map(\.ref).sorted(), ["bad", "ok"])
        XCTAssertEqual(events.first { $0.ref == "bad" }?.kind, .sessionFailed)
        XCTAssertEqual(events.first { $0.ref == "ok" }?.detail, "Summary ok.")
    }
}

final class ActionItemsOpenTests: XCTestCase {
    func testOpenItemsAreUntickedAndMineOrUnowned() {
        let summary = """
        # Summary
        - [ ] Not an action item

        ## Action items
        - [ ] Send the notes (owner: Me, due: Friday)
        - [x] Book the room (owner: Me)
        - [ ] Update pricing (owner: Priya)
        - [ ] Check the numbers
        """
        XCTAssertEqual(ActionItems.openItems(summary).map(\.title), ["Send the notes", "Check the numbers"])
    }
}

/// `catchUpMinutes` on a daily trigger: the latest missed slot fires once within the grace period, older ones are dropped,
/// and a slot that passed before the automation was turned on or first seen never fires.
final class DailyCatchUpTests: AutomationTestCase {
    private func daily(_ id: String, at time: String, grace: Double?, enabled: Bool = true) -> Automation {
        Automation(id: id, name: id, enabled: enabled,
                   trigger: .init(type: "daily", times: [time], weekdays: AutomationDefaults.weekdays, catchUpMinutes: grace),
                   action: .init(type: "bubble", title: id, body: ""), createdBy: "user")
    }

    private func fired(_ rig: Rig, _ id: String) -> Int {
        rig.service.history(id, limit: 50).filter { $0["outcome"] == "fired" }.count
    }

    private func wake(_ rig: Rig, at date: Date) {
        clock.now = date
        rig.engine.tick()
    }

    func testAMissedSlotFiresOnWakeWithinGrace() {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        wake(rig, at: AutomationTestClock.monday(hour: 10, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 1)
        run(rig, minutes: 5)
        XCTAssertEqual(fired(rig, "brief"), 1)
    }

    func testOnTimeItFiresOnce() {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        run(rig, minutes: 62)
        XCTAssertEqual(fired(rig, "brief"), 1)
    }

    func testASlotPastGraceIsDroppedAndTheNextOneFires() {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        wake(rig, at: AutomationTestClock.monday(hour: 12, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 0)
        wake(rig, at: AutomationTestClock.monday(plus: 1, hour: 9))
        XCTAssertEqual(fired(rig, "brief"), 1)
    }

    func testOvernightSleepGivesOnlyTheMorningBrief() {
        clock.now = AutomationTestClock.monday(hour: 17)
        let rig = makeRig([daily("brief", at: "09:00", grace: 180), daily("recap", at: "18:00", grace: 120)])
        wake(rig, at: AutomationTestClock.monday(plus: 1, hour: 9, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 1)
        XCTAssertEqual(fired(rig, "recap"), 0)
    }

    func testASlotMissedWhileIronpetWasNotRunningCatchesUpOnceAtLaunch() {
        _ = makeRig([daily("brief", at: "09:00", grace: 180)])
        clock.now = AutomationTestClock.monday(hour: 10)
        let launched = makeRig([daily("brief", at: "09:00", grace: 180)])
        launched.engine.tick()
        XCTAssertEqual(fired(launched, "brief"), 1)
        clock.now = AutomationTestClock.monday(hour: 10, minute: 5)
        let again = makeRig([daily("brief", at: "09:00", grace: 180)])
        again.engine.tick()
        XCTAssertEqual(fired(again, "brief"), 1, "the slot is stored, so a second launch does not repeat it")
    }

    func testTheFirstLaunchAfterTheSlotDoesNotFire() {
        clock.now = AutomationTestClock.monday(hour: 10)
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        rig.engine.tick()
        XCTAssertEqual(fired(rig, "brief"), 0)
    }

    func testTurningItOnAfterTheSlotWaitsForTomorrow() throws {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180, enabled: false)])
        wake(rig, at: AutomationTestClock.monday(hour: 10))
        try rig.store.update("brief") { $0.enabled = true }
        rig.engine.tick()
        XCTAssertEqual(fired(rig, "brief"), 0)
        wake(rig, at: AutomationTestClock.monday(plus: 1, hour: 9, minute: 1))
        XCTAssertEqual(fired(rig, "brief"), 1)
    }

    func testMovingTheTimeEarlierDoesNotFireToday() throws {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        wake(rig, at: AutomationTestClock.monday(hour: 8, minute: 30))
        try rig.store.update("brief") { $0.trigger.times = ["08:15"] }
        rig.engine.tick()
        XCTAssertEqual(fired(rig, "brief"), 0)
    }

    func testWeekendsAreSkipped() {
        clock.now = AutomationTestClock.monday(plus: 4, hour: 10)
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)])
        wake(rig, at: AutomationTestClock.monday(plus: 5, hour: 9, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 0, "Saturday")
        wake(rig, at: AutomationTestClock.monday(plus: 7, hour: 9, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 1, "Monday")
    }

    func testPausedRemindersHoldIt() {
        let rig = makeRig([daily("brief", at: "09:00", grace: 180)], timing: .init(paused: true))
        wake(rig, at: AutomationTestClock.monday(hour: 9, minute: 30))
        XCTAssertEqual(fired(rig, "brief"), 0)
    }

    func testTheSlotTableReachesADatabaseAlreadyPastEveryOtherMigration() throws {
        let file = dir.appendingPathComponent("app.db")
        var old: Database? = try Database(path: file, migrations: AppMigrations.all.filter { $0.version <= 305 })
        XCTAssertEqual(old?.schemaVersion, 305)
        old = nil
        let state = AutomationState(database: try Database(path: file, migrations: AppMigrations.all))
        state.setDailySlot("brief", AutomationTestClock.monday8)
        XCTAssertEqual(state.dailySlot("brief"), AutomationTestClock.monday8)
    }

    func testValidation() {
        var a = daily("brief", at: "09:00", grace: 721)
        XCTAssertTrue(AutomationValidator.validate(a).contains("trigger.catchUpMinutes must be a number from 0 to 720"))
        a.trigger.catchUpMinutes = 0
        XCTAssertEqual(AutomationValidator.validate(a), [])
    }
}

/// The built-in `morning-brief` and `day-recap` automations and the `digest` action.
final class DigestAutomationTests: AutomationTestCase {
    private typealias F = BriefFixture
    private var shown: [(kind: Brief.Kind, manual: Bool)] = []
    private var next = Brief(kind: .brief, window: DateInterval(start: .distantPast, end: .distantPast), sections: [], lines: [])

    private var nonEmpty: Brief {
        Brief(kind: .brief, window: DateInterval(start: F.startOfTuesday, end: F.tuesday(hour: 9)),
              sections: [.init(id: "due", title: "Due", items: [.init(id: "due:x", symbol: "calendar", title: "X", target: .task("x"))])],
              lines: ["1 task due today"])
    }

    private func wired(_ automations: [Automation]) -> Rig {
        let rig = makeRig(automations)
        shown = []
        rig.service.digest = { [unowned self] kind, _ in var b = next; b.kind = kind; return b }
        rig.service.showDigest = { [unowned self] brief, _, manual in shown.append((brief.kind, manual)) }
        return rig
    }

    private func history(_ rig: Rig, _ id: String) -> [String] {
        rig.service.history(id, limit: 20).map { "\($0["outcome"] ?? ""): \($0["output"] ?? "")" }
    }

    func testFreshAndExistingFilesGetBothOff() {
        let fresh = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        for id in [AutomationDefaults.morningBriefID, AutomationDefaults.dayRecapID] {
            guard let a = fresh.automations.first(where: { $0.id == id }) else { return XCTFail("\(id) missing") }
            XCTAssertFalse(a.enabled)
            XCTAssertEqual(a.action.type, "digest")
            XCTAssertEqual(a.trigger.weekdays, AutomationDefaults.weekdays)
            XCTAssertEqual(AutomationValidator.validate(a), [])
            XCTAssertFalse(AutomationService(store: fresh, engine: AutomationEngine(env: clock.environment)).needsApproval(a))
        }
        XCTAssertEqual(fresh.automations.first { $0.id == AutomationDefaults.morningBriefID }?.trigger.times, ["09:00"])
        XCTAssertEqual(fresh.automations.first { $0.id == AutomationDefaults.dayRecapID }?.trigger.times, ["18:00"])
    }

    func testTurningOnPersistsAndADeletedOneComesBackOff() throws {
        let store = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        try store.update(AutomationDefaults.morningBriefID) { $0.enabled = true; $0.trigger.times = ["08:30"] }
        try store.replace(store.automations.filter { $0.id != AutomationDefaults.dayRecapID })
        let restarted = AutomationStore(paths: paths, defaults: { [] }, builtIns: AutomationDefaults.builtIns, watch: false)
        let brief = restarted.automations.first { $0.id == AutomationDefaults.morningBriefID }
        XCTAssertEqual(brief?.enabled, true)
        XCTAssertEqual(brief?.trigger.times, ["08:30"])
        XCTAssertEqual(restarted.automations.first { $0.id == AutomationDefaults.dayRecapID }?.enabled, false)
    }

    func testAScheduledBriefShowsAndRecords() {
        next = nonEmpty
        let rig = wired([AutomationDefaults.morningBrief(enabled: true)])
        run(rig, minutes: 61)
        XCTAssertEqual(shown.map(\.kind), [.brief])
        XCTAssertEqual(shown.first?.manual, false)
        XCTAssertTrue(history(rig, AutomationDefaults.morningBriefID).contains("fired: 1 task due today"))
    }

    func testAnEmptyScheduledBriefStaysQuietButRunNowShowsIt() async {
        let rig = wired([AutomationDefaults.morningBrief(enabled: true)])
        run(rig, minutes: 61)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(history(rig, AutomationDefaults.morningBriefID).contains("ok: nothing to report"))
        _ = await rig.service.call("run_now", ["id": AutomationDefaults.morningBriefID], by: "user")
        XCTAssertEqual(shown.map(\.manual), [true])
    }

    func testTheRecapAsksForTheRecap() {
        next = nonEmpty
        clock.now = AutomationTestClock.monday(hour: 17, minute: 30)
        let rig = wired([AutomationDefaults.dayRecap(enabled: true)])
        run(rig, minutes: 31)
        XCTAssertEqual(shown.map(\.kind), [.recap])
    }

    func testValidation() {
        var a = AutomationDefaults.morningBrief()
        a.action.digest = "weekly"
        XCTAssertTrue(AutomationValidator.validate(a).contains("action.digest must be one of brief, recap"))
        let (parsed, errors) = AutomationValidator.parseOne([
            "id": "poll-digest", "name": "x", "trigger": ["type": "poll", "minutes": 5, "source": ["type": "shell", "command": "true"]],
            "action": ["type": "digest", "digest": "brief"]])
        XCTAssertEqual(errors, [])
        XCTAssertTrue(AutomationValidator.validate(parsed!).contains { $0.contains("not a poll") })
        XCTAssertTrue(AutomationSchema.json.contains("\"digest\""))
        XCTAssertTrue(AutomationSchema.json.contains("catchUpMinutes"))
    }
}

@MainActor
final class BriefBubbleTests: XCTestCase {
    private typealias F = BriefFixture

    func testTheBubbleShowsTheLinesAndStaysUntilTheEndOfTheDay() {
        let now = F.tuesday(hour: 9)
        let brief = Brief(kind: .brief, window: DateInterval(start: now, end: now),
                          sections: [.init(id: "due", title: "Due", items: [.init(id: "d", symbol: "calendar", title: "X", target: .task("x"))])],
                          lines: ["a", "b", "c", "d", "e"])
        var opened = 0
        let bubble = Announcer.briefBubble(brief, automation: AutomationDefaults.morningBrief(), now: now, calendar: F.calendar) { opened += 1 }
        XCTAssertEqual(bubble.id, "digest:brief")
        XCTAssertEqual(bubble.title, "Morning brief")
        XCTAssertEqual(bubble.body, "a\nb\nc\nd")
        XCTAssertEqual(bubble.expires, F.calendar.date(byAdding: .day, value: 1, to: F.startOfTuesday))
        XCTAssertEqual(bubble.actions.map(\.title), ["Open"])
        bubble.onTap?()
        bubble.actions.first?.run()
        XCTAssertEqual(opened, 2)
    }

    func testAnEmptyRecapSaysSoBriefly() {
        let now = F.tuesday(hour: 18)
        var automation = AutomationDefaults.dayRecap()
        automation.action.title = "Wrap-up"
        let bubble = Announcer.briefBubble(Brief(kind: .recap, window: DateInterval(start: now, end: now), sections: [], lines: []),
                                           automation: automation, now: now, calendar: F.calendar) {}
        XCTAssertEqual(bubble.id, "digest:recap")
        XCTAssertEqual(bubble.title, "Wrap-up")
        XCTAssertEqual(bubble.body, "Nothing to report")
        XCTAssertEqual(bubble.expires, now.addingTimeInterval(15))
    }
}

final class DailyScheduleTests: XCTestCase {
    private let calendar = AutomationTestClock.calendar

    func testOnlyADailyTriggerWithOneTimeIsEditable() {
        let now = AutomationTestClock.monday8
        let one = Automation.Trigger(type: "daily", times: ["18:30"])
        XCTAssertEqual(DailySchedule.time(of: one, now: now, calendar: calendar), AutomationTestClock.monday(hour: 18, minute: 30))
        XCTAssertNil(DailySchedule.time(of: .init(type: "daily", times: ["09:00", "18:00"]), now: now, calendar: calendar))
        XCTAssertNil(DailySchedule.time(of: .init(type: "interval", minutes: 5), now: now, calendar: calendar))
        XCTAssertEqual(DailySchedule.format(AutomationTestClock.monday(hour: 7, minute: 5), calendar: calendar), "07:05")
    }

    func testWeekdaysOnlyIsShownForEveryDayOrMondayToFriday() {
        XCTAssertEqual(DailySchedule.weekdaysOnly(.init(type: "daily", times: ["09:00"], weekdays: AutomationDefaults.weekdays)), true)
        XCTAssertEqual(DailySchedule.weekdaysOnly(.init(type: "daily", times: ["09:00"])), false)
        XCTAssertNil(DailySchedule.weekdaysOnly(.init(type: "daily", times: ["09:00"], weekdays: ["mon", "wed"])))
        XCTAssertEqual(DailySchedule.weekdays(only: true), AutomationDefaults.weekdays)
        XCTAssertNil(DailySchedule.weekdays(only: false))
    }
}

@MainActor
final class TodaySectionTests: XCTestCase {
    func testTodayIsListedLastOnlyWhenABriefAutomationIsOn() {
        let hidden = IronPetSection.shown(chat: true, transcripts: true, automations: true)
        XCTAssertFalse(hidden.contains(.today))
        let shown = IronPetSection.shown(chat: true, transcripts: true, automations: true, today: true)
        XCTAssertEqual(shown.last, .today)
        XCTAssertEqual(IronPetSection.forShortcut("8", in: shown), .today)
        XCTAssertEqual(Array(shown.dropLast()), hidden, "the other rows keep their shortcuts")
        XCTAssertTrue(IronPetSection.today.hidesBubbles)
    }

    func testHidingTodayMovesOffThePage() {
        let model = IronPetWindowModel(defaults: UserDefaults(suiteName: "ironpet-tests-\(UUID().uuidString)")!)
        model.todayShown = true
        model.section = .today
        model.todayShown = false
        XCTAssertEqual(model.section, .chat)
    }
}
