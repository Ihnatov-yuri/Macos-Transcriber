import XCTest
@testable import Transcriberr

/// The person page's brief (5.0.0): what is sent to the text engine, how
/// its answer is read, and how meetings combine.
final class PersonBriefTests: XCTestCase {
    private let lines: [PersonBriefBuilder.Line] = [
        .init(start: 5, speaker: "Anna", text: "Hi all."),
        .init(start: 12, speaker: "Yuri", text: "Kate, can you send the deck?"),
        .init(start: 20, speaker: "Kate", text: "Yes, by Friday."),
        .init(start: 31, speaker: "Anna", text: "Unrelated chatter."),
        .init(start: 40, speaker: "Anna", text: "More chatter."),
        .init(start: 3725, speaker: "kate", text: "Who owns pricing?"),
    ]

    func testTranscriptKeepsTheirLinesAndTheOneBefore() {
        let t = PersonBriefBuilder.transcript(lines, name: "Kate")
        XCTAssertEqual(t, """
        [00:12] Yuri: Kate, can you send the deck?
        [00:20] Kate: Yes, by Friday.
        [00:40] Anna: More chatter.
        [1:02:05] kate: Who owns pricing?
        """)
    }

    func testParseSnapsTimesToTheirLinesAndDropsJunk() {
        let raw = """
        Here is the answer:
        COMMIT: [00:21] Send the deck to Yuri by Friday
        - QUESTION: [1:02:05] Who owns pricing?
        QUESTION: none
        TOPIC: [09:00] Pricing => Wants one owner for it
        TOPIC: no arrow here
        COMMIT: Book the room
        """
        let b = PersonBriefBuilder.parse(raw, lineStarts: [20, 3725])
        XCTAssertEqual(b.commitments, [.init(text: "Send the deck to Yuri by Friday", seconds: 20),
                                       .init(text: "Book the room", seconds: nil)])
        XCTAssertEqual(b.questions, [.init(text: "Who owns pricing?", seconds: 3725)])
        XCTAssertEqual(b.topics, [.init(text: "Wants one owner for it", seconds: nil, topic: "Pricing")],
                       "09:00 is nowhere near one of their lines")
    }

    func testParseDropsCopiedNamesAndBadTimes() {
        let raw = """
        COMMIT: [04:31] Lana: I will drop it in the chat.
        TOPIC: [0:0:0:7] Meeting intro => I will record this meeting.
        TOPIC: [01:00] Q3: budget => Over by 10%.
        """
        let b = PersonBriefBuilder.parse(raw, lineStarts: [271])
        XCTAssertEqual(b.commitments.first?.text, "I will drop it in the chat.")
        XCTAssertEqual(b.commitments.first?.seconds, 271)
        XCTAssertEqual(b.topics.first?.topic, "Meeting intro")
        XCTAssertEqual(b.topics.last?.topic, "Q3: budget", "a colon inside a topic with a digit is kept")
    }

    func testDoneMarksSurviveARewording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("briefs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersonBriefStore(url: url)
        let person = UUID(), rec = UUID()
        let old = PersonBrief(commitments: [.init(text: "Lana: I will send the kiosk video to Yuri tomorrow"), .init(text: "Book the room")])
        try store.setClosed(PersonBriefStore.itemKey(rec, "commitment", old.commitments[0].text), true, for: person)
        let new = PersonBrief(commitments: [.init(text: "I will send the kiosk video to Yuri by tomorrow"), .init(text: "Book a meeting room")])
        store.carryClosed(from: old, to: new, recording: rec, for: person)
        let closed = store.closed(for: person)
        XCTAssertTrue(closed.contains(PersonBriefStore.itemKey(rec, "commitment", new.commitments[0].text)))
        XCTAssertFalse(closed.contains(PersonBriefStore.itemKey(rec, "commitment", new.commitments[1].text)))
    }

    func testMergeDedupesAndLaterTopicWins() {
        var a = PersonBrief(commitments: [.init(text: "Send the deck")],
                            topics: [.init(text: "Too high", topic: "Pricing")])
        PersonBriefBuilder.merge(PersonBrief(commitments: [.init(text: "send the deck"), .init(text: "Call Anna")],
                                             topics: [.init(text: "Fine now", topic: "pricing")]), into: &a)
        XCTAssertEqual(a.commitments.map(\.text), ["Send the deck", "Call Anna"])
        XCTAssertEqual(a.topics.map(\.text), ["Fine now"])
    }

    func testBuildReadsEverySectionAndThrowsOnlyWhenAllFail() async throws {
        var calls = 0
        let b = try await PersonBriefBuilder.build(transcript: "[00:20] Kate: Yes", name: "Kate", lineStarts: [20]) { system, user, _ in
            calls += 1
            XCTAssertTrue(system.contains("what Kate said"))
            XCTAssertTrue(user.hasPrefix("TRANSCRIPT:\n"))
            return "COMMIT: [00:20] Send it"
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(b.brief.commitments.first?.seconds, 20)
        XCTAssertTrue(b.complete)

        struct Boom: Error {}
        do {
            _ = try await PersonBriefBuilder.build(transcript: "x", name: "Kate", lineStarts: []) { _, _, _ in throw Boom() }
            XCTFail("every section failed")
        } catch is Boom {}
    }

    func testLanguageIsNamedFromTheirWordsAndNeverRussian() {
        let uk = PersonBriefBuilder.transcript([
            .init(start: 64, speaker: "Iryna", text: "Що з цього сьогодні для тебе найважливіше, з чого почати?"),
            .init(start: 3725, speaker: "Iryna", text: "Як тобі відгукується почати з глобального чи з точкового підходу до вибору сфери?"),
        ], name: "Iryna")
        XCTAssertEqual(PersonBriefBuilder.language(of: uk), "Ukrainian")
        let en = PersonBriefBuilder.transcript(lines, name: "Kate") + "\n[00:50] Kate: I will send the updated pricing deck to the whole team before the review."
        XCTAssertEqual(PersonBriefBuilder.language(of: en), "English")
        XCTAssertNil(PersonBriefBuilder.language(of: "[00:01] Kate: Ok."))
    }

    func testBuildNamesTheLanguageInEverySection() async throws {
        let uk = PersonBriefBuilder.transcript([
            .init(start: 64, speaker: "Iryna", text: "Що з цього сьогодні для тебе найважливіше, з чого почати?"),
            .init(start: 90, speaker: "Iryna", text: "Я надішлю тобі підсумок нашої розмови сьогодні ввечері."),
        ], name: "Iryna")
        var systems: [String] = []
        _ = try await PersonBriefBuilder.build(transcript: uk, name: "Iryna", lineStarts: [64, 90]) { system, _, _ in
            systems.append(system)
            return "GIST: Підсумок."
        }
        XCTAssertFalse(systems.isEmpty)
        XCTAssertTrue(systems.allSatisfy { $0.contains("Write in Ukrainian, the language of the transcript") })
        XCTAssertTrue(PersonBriefBuilder.systemPrompt(name: "Kate").contains("Write in the language of the transcript."))
    }

    func testCacheKeyChangesWithInputAndName() {
        let k = PersonBriefBuilder.key(transcript: "a", name: "Kate")
        XCTAssertEqual(k, PersonBriefBuilder.key(transcript: "a", name: "Kate"))
        XCTAssertNotEqual(k, PersonBriefBuilder.key(transcript: "b", name: "Kate"))
        XCTAssertNotEqual(k, PersonBriefBuilder.key(transcript: "a", name: "Anna"))
    }

    func testCombineIsNewestFirstAndKeepsTheLastWordOnATopic() {
        func meeting(_ day: Double) -> PersonMeeting {
            PersonMeeting(id: UUID(), title: "M\(Int(day))", date: Date(timeIntervalSince1970: day * 86_400),
                          seconds: 60, lines: 3, firstLine: 10, keys: ["S1"], lastSaid: "bye")
        }
        let new = meeting(2), old = meeting(1), unread = meeting(3)
        let entries = [
            PersonBriefStore.Entry(recordingId: old.id, key: "", built: Date(), brief: PersonBrief(
                commitments: [.init(text: "Old promise")], topics: [.init(text: "Too high", topic: "Pricing")])),
            PersonBriefStore.Entry(recordingId: new.id, key: "", built: Date(), brief: PersonBrief(
                commitments: [.init(text: "New promise")], topics: [.init(text: "Fine now", topic: "pricing")])),
        ]
        let v = PersonBriefView.combine(entries, meetings: [unread, new, old])
        XCTAssertEqual(v.readMeetings, 2)
        XCTAssertEqual(v.commitments.map(\.item.text), ["New promise", "Old promise"])
        XCTAssertEqual(v.topics.map(\.item.text), ["Fine now"])
        XCTAssertEqual(v.topics.first?.meeting.id, new.id)
    }

    // MARK: - Periods and summaries

    private func meeting(daysAgo: Double, now: Date) -> PersonMeeting {
        PersonMeeting(id: UUID(), title: "M\(Int(daysAgo))", date: now.addingTimeInterval(-daysAgo * 86_400),
                      seconds: 60, lines: 3, firstLine: 10, keys: ["S1"], lastSaid: "bye")
    }

    func testParseReadsTheGistAndMergeKeepsSectionOrder() {
        let a = PersonBriefBuilder.parse("GIST: Kate reported the kiosk launch slipped a week.\nCOMMIT: [00:10] Send the plan", lineStarts: [10])
        XCTAssertEqual(a.gist, ["Kate reported the kiosk launch slipped a week."])
        var merged = a
        PersonBriefBuilder.merge(PersonBriefBuilder.parse("SUMMARY: She asked for more testers.", lineStarts: []), into: &merged)
        XCTAssertEqual(merged.gist, ["Kate reported the kiosk launch slipped a week.", "She asked for more testers."])
        XCTAssertFalse(PersonBrief(gist: ["Only a summary"]).isEmpty)
    }

    func testPeriodsPickTheirMeetings() {
        let now = Date()
        let m1 = meeting(daysAgo: 2, now: now), m2 = meeting(daysAgo: 5, now: now)
        let m3 = meeting(daysAgo: 20, now: now), m4 = meeting(daysAgo: 60, now: now)
        let all = [m1, m2, m3, m4]
        XCTAssertEqual(PersonBriefView.meetings(all, in: .lastMeeting, now: now).map(\.id), [m1.id])
        XCTAssertEqual(PersonBriefView.meetings(all, in: .week, now: now).map(\.id), [m1.id, m2.id])
        XCTAssertEqual(PersonBriefView.meetings(all, in: .month, now: now).map(\.id), [m1.id, m2.id, m3.id])
        XCTAssertEqual(PersonBriefView.meetings(all, in: nil, now: now).count, 4)
        // The last meeting is theirs however long ago it was.
        XCTAssertEqual(PersonBriefView.meetings([m4], in: .lastMeeting, now: now).map(\.id), [m4.id])
        XCTAssertTrue(PersonBriefView.meetings([m4], in: .week, now: now).isEmpty)
    }

    func testCombineForAPeriodCountsUnreadAndShowsGists() {
        let now = Date()
        let read = meeting(daysAgo: 1, now: now), unread = meeting(daysAgo: 3, now: now), old = meeting(daysAgo: 40, now: now)
        let entries = [
            PersonBriefStore.Entry(recordingId: read.id, key: "", built: now, brief: PersonBrief(gist: ["Asked about pricing.", "Agreed to a pilot."])),
            PersonBriefStore.Entry(recordingId: old.id, key: "", built: now, brief: PersonBrief(commitments: [.init(text: "Old promise")])),
        ]
        let week = PersonBriefView.combine(entries, meetings: [read, unread, old], period: .week, now: now)
        XCTAssertEqual(week.meetings.count, 2)
        XCTAssertEqual(week.readMeetings, 1)
        XCTAssertEqual(week.unread, 1)
        XCTAssertEqual(week.gists.map(\.text), ["Asked about pricing. Agreed to a pilot."])
        XCTAssertTrue(week.commitments.isEmpty, "a commitment from 40 days ago is not last week's")
        XCTAssertEqual(PersonBriefView.combine(entries, meetings: [read, unread, old], now: now).commitments.count, 1)
    }

    func testTheSameCommitmentInTwoMeetingsShowsOnceFromTheNewest() {
        let now = Date()
        let new = meeting(daysAgo: 1, now: now), old = meeting(daysAgo: 2, now: now)
        let entries = [
            PersonBriefStore.Entry(recordingId: old.id, key: "", built: now, brief: PersonBrief(
                commitments: [.init(text: "I will follow up with the rest of the team"), .init(text: "Share the design file")])),
            PersonBriefStore.Entry(recordingId: new.id, key: "", built: now, brief: PersonBrief(
                commitments: [.init(text: "I will follow up with the rest of the team.")])),
        ]
        let v = PersonBriefView.combine(entries, meetings: [new, old], period: .month, now: now)
        XCTAssertEqual(v.commitments.map(\.meeting.id), [new.id, old.id])
        XCTAssertEqual(v.commitments.map(\.item.text), ["I will follow up with the rest of the team.", "Share the design file"])
    }

    @MainActor
    func testAReadCoversTheMonthAndAlwaysTheNewest() {
        let now = Date()
        let recent = (0..<20).map { meeting(daysAgo: Double($0), now: now) }
        XCTAssertEqual(PersonBriefRunner.toRead(recent, now: now).count, PersonBriefBuilder.maxMeetings)
        let old = [meeting(daysAgo: 50, now: now), meeting(daysAgo: 80, now: now)]
        XCTAssertEqual(PersonBriefRunner.toRead(old, now: now).map(\.id), [old[0].id])
        let mixed = [meeting(daysAgo: 3, now: now), meeting(daysAgo: 25, now: now), meeting(daysAgo: 45, now: now)]
        XCTAssertEqual(PersonBriefRunner.toRead(mixed, now: now).count, 2)
    }

    func testCommitmentsReadAsToDosAndOthersTasksAreDropped() {
        let raw = """
        COMMIT: [00:10] Lana will share the video recording with Yuri.
        COMMIT: [00:10] Send an email to Lana with feedback on the interface.
        COMMIT: [00:10] Pull up an email and ask for a new video.
        """
        let b = PersonBriefBuilder.parse(raw, lineStarts: [10], name: "Lana")
        XCTAssertEqual(b.commitments.map(\.text), ["Share the video recording with Yuri.", "Pull up an email and ask for a new video."])
        XCTAssertEqual(PersonBriefBuilder.task("Lana is going to call the bank", name: "Lana Smith"), "Call the bank")
        XCTAssertEqual(PersonBriefBuilder.task("Call the bank", name: nil), "Call the bank")
    }

    func testDoneSurvivesTurningAPromiseIntoAToDo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brief-\(UUID().uuidString.prefix(6))")
        let store = PersonBriefStore(url: dir.appendingPathComponent("b.json"))
        let person = UUID(), rec = UUID()
        let old = PersonBrief(commitments: [.init(text: "I will ask them to join as well.")])
        let new = PersonBrief(commitments: [.init(text: "Ask them to join as well.")])
        try store.setClosed(PersonBriefStore.itemKey(rec, "commitment", old.commitments[0].text), true, for: person)
        store.carryClosed(from: old, to: new, recording: rec, for: person)
        XCTAssertTrue(store.closed(for: person).contains(PersonBriefStore.itemKey(rec, "commitment", "Ask them to join as well.")))
    }
}
