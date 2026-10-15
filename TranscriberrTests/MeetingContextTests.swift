import XCTest
@testable import Transcriberr

final class MeetingContextTests: XCTestCase {
    func testInviteTextYieldsNamesNotBoilerplate() {
        let notes = """
        Hi all, let's go through the Kaiko pilot with Blits Insurance and the LLMs4EU proposal.
        ________________________________________________________________________________
        Microsoft Teams Need help? Join the meeting now
        Meeting ID: 377 410 552 Passcode: Xy7Pq2
        https://teams.microsoft.com/l/meetup-join/19%3ameeting
        """
        let terms = MeetingContext.terms(in: "Weekly sync: Kaiko roadmap\n" + notes)
        XCTAssertTrue(terms.contains("Kaiko"), "\(terms)")
        XCTAssertTrue(terms.contains("Blits Insurance"), "\(terms)")
        XCTAssertTrue(terms.contains("Blits"), "\(terms)")
        XCTAssertTrue(terms.contains("LLMs4EU"), "\(terms)")
        for junk in ["Microsoft", "Teams", "Meeting", "Passcode", "Join", "Hi", "Weekly"] {
            XCTAssertFalse(terms.contains(junk), "\(junk) in \(terms)")
        }
        XCTAssertFalse(terms.contains { $0.contains("teams.microsoft") }, "\(terms)")
    }

    func testCalendarTermsSplitAttendeeNames() {
        let mc = MeetingContext(title: "Kaiko pilot", attendees: ["Kees van Dijk", "Haya Ahmed"], emails: [],
                                inviteTerms: ["Kaiko"], start: Date(), end: Date())
        XCTAssertEqual(mc.calendarTerms, ["Kees van Dijk", "Kees", "Dijk", "Haya Ahmed", "Haya", "Ahmed", "Kaiko"])
        XCTAssertEqual(mc.promptLine, "Meeting: Kaiko pilot. Attendees: Kees van Dijk, Haya Ahmed.")
    }

    func testRecurringTermsNeedTwoMeetingsOrThreeMentions() {
        let past = [
            "We talked to Neona about it. Then Victor joined and Neona left.",
            "As Neona said, the Agentbank demo is ready.",
            "The Marvelx thing. Ask Marvelx. And Marvelx again.",
        ]
        let r = MeetingContext.recurringTerms(in: past, excluding: ["Victor"])
        XCTAssertEqual(r.first, "Neona")
        XCTAssertTrue(r.contains("Marvelx"))       // three times in one
        XCTAssertFalse(r.contains("Agentbank"))    // once
        XCTAssertFalse(r.contains("Victor"))       // already a calendar term
    }

    func testRecordedIntervalOnlyForRecordingsMadeInTheApp() {
        // A meeting's name carries its start; the row is created at Stop.
        let m = MeetingContext.recordedInterval(audioPath: "/x/meeting_1790149550450_1B9D6EC8.m4a",
                                                createdAtMillis: 1_790_152_000_000, duration: 1800)
        XCTAssertEqual(m?.start.timeIntervalSince1970 ?? 0, 1_790_149_550.45, accuracy: 0.01)
        XCTAssertEqual(m?.duration, 1800)
        // A voice recording's name carries its start (local time), also for
        // one recovered after a crash, whose row was made from the file.
        let r = MeetingContext.recordedInterval(audioPath: "/x/Recording_2026-10-15_10-00-00-123.m4a",
                                                createdAtMillis: 1, duration: 600)
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 15; c.hour = 10
        XCTAssertEqual(r?.start, Calendar.current.date(from: c))
        XCTAssertEqual(r?.duration, 600)
        // Unreadable stamp: the row was created at Stop.
        let r2 = MeetingContext.recordedInterval(audioPath: "/x/Recording_garbled.m4a",
                                                 createdAtMillis: 1_790_000_600_000, duration: 600)
        XCTAssertEqual(r2?.start.timeIntervalSince1970 ?? 0, 1_790_000_000, accuracy: 0.01)
        for name in ["merged_1790_ABC.m4a", "split_1790333658016_b_CBCFECED.m4a", "Cees and Gigs.m4a",
                     "WhatsApp Audio 2026-10-13 at 10.35.06.opus"] {
            XCTAssertNil(MeetingContext.recordedInterval(audioPath: "/x/" + name, createdAtMillis: 1, duration: 60), name)
        }
    }

    func testOnlyCoinedInviteWordsAreForcedSpellings() {
        XCTAssertTrue(MeetingContext.isCoined("Kaiko"))
        XCTAssertTrue(MeetingContext.isCoined("LLMs4EU"))
        XCTAssertTrue(MeetingContext.isCoined("Landal Insurance"))
        XCTAssertTrue(MeetingContext.isCoined("Agentbank"))
        XCTAssertFalse(MeetingContext.isCoined("Rollout"))
        XCTAssertFalse(MeetingContext.isCoined("Planning"))
        XCTAssertFalse(MeetingContext.isCoined("Design"))
    }

    func testPastTermsAreHintsNotSpellings() {
        let mc = MeetingContext(title: "Kaiko pilot", attendees: ["Haya Ahmed"], emails: [], inviteTerms: [],
                                pastTerms: ["Kaico"], pastMeetings: 2, start: Date(), end: Date())
        XCTAssertFalse(mc.allTerms.contains("Kaico"))
        XCTAssertTrue(mc.promptBlock.contains("hints only): Kaico"))
        // A long attendee list is capped and cannot crowd out what follows.
        let many = MeetingContext(title: "All hands", attendees: (1...60).map { "Person Number\($0)" }, emails: [],
                                  inviteTerms: [], start: Date(), end: Date())
        XCTAssertLessThan(many.promptBlock.count, 2000)
    }

    func testRecurringTermsSkipNearMissesOfTheVocabulary() {
        let past = ["We met Kaico. Then Kaico left.", "Ask Kaico and Neona.", "Neona again, with Neona."]
        let r = MeetingContext.recurringTerms(in: past, excluding: ["Kaiko"])
        XCTAssertFalse(r.contains("Kaico"), "\(r)")
        XCTAssertTrue(r.contains("Neona"), "\(r)")
    }

    func testRoundTrip() {
        let mc = MeetingContext(title: "t", attendees: ["A B"], emails: ["a@b.c"], inviteTerms: [],
                                pastTerms: ["X"], pastMeetings: 2, start: Date(timeIntervalSince1970: 0),
                                end: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(MeetingContext.decode(MeetingContext.encode(mc)), mc)
    }

    func testUkrainianInviteText() {
        let t = MeetingContext.terms(in: "Зустріч з командою Kaiko щодо пілоту LLMs4EU. Обговоримо бюджет з Оленою Коваль.")
        XCTAssertTrue(t.contains("Kaiko"), "\(t)")
        XCTAssertTrue(t.contains("LLMs4EU"), "\(t)")
        XCTAssertTrue(t.contains("Оленою Коваль") || t.contains("Коваль"), "\(t)")
        XCTAssertFalse(t.contains("Зустріч"), "\(t)")   // sentence start
    }

    func testTheSharedEngineForgetsThePreviousMeeting() async {
        let ens = EnsembleBackend(factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore()))
        await ens.setMeetingContext(MeetingContext(title: "x", attendees: ["Haya Ahmed"], emails: [], inviteTerms: ["Kaiko"],
                                                   start: Date(), end: Date()))
        let during = await ens.meetingVocabulary()
        XCTAssertTrue(during.isSuperset(of: ["haya", "ahmed", "kaiko"]), "\(during)")
        await ens.setMeetingContext(nil)
        let after = await ens.meetingVocabulary()
        XCTAssertTrue(after.isEmpty)
    }
}
