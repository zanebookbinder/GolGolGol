import Testing
@testable import GoalKit

struct SnapshotParserTests {
    @Test func parsesReportLayout() throws {
        let text = """
        DATE 2026-09-28
        SCREEN TIME
        134 min
        PICKUPS
        87
        """
        #expect(try SnapshotParser.parse(text) == SnapshotReading(screenTimeMinutes: 134, pickups: 87, day: "2026-09-28"))
    }

    @Test func parsesHoursAndMinutes() throws {
        let reading = try SnapshotParser.parse("Screen Time\n2h 14m\nPickups\n87")
        #expect(reading.screenTimeMinutes == 134)
    }

    @Test func parsesHoursOnly() throws {
        #expect(try SnapshotParser.parse("SCREEN TIME\n3 hr").screenTimeMinutes == 180)
    }

    @Test func parsesValuesOnSameLineAsLabel() throws {
        let reading = try SnapshotParser.parse("SCREEN TIME 45 min PICKUPS 12")
        #expect(reading.screenTimeMinutes == 45)
        #expect(reading.pickups == 12)
    }

    @Test func fixesCommonDigitMisreads() throws {
        let reading = try SnapshotParser.parse("SCREEN TIME\n1O4 min\nPICKUPS\nl2")
        #expect(reading.screenTimeMinutes == 104)
        #expect(reading.pickups == 12)
    }

    @Test func ignoresNoiseAroundTheReport() throws {
        let text = """
        9:41
        SCREEN TIME
        134 min
        PICKUPS
        87
        Close
        """
        let reading = try SnapshotParser.parse(text)
        #expect(reading.screenTimeMinutes == 134)
        #expect(reading.pickups == 87)
        #expect(reading.day == nil)
    }

    @Test func doesNotBorrowPickupsWhenScreenTimeIsUnreadable() {
        #expect(throws: SnapshotParseError.screenTimeNotFound) {
            try SnapshotParser.parse("SCREEN TIME\n???\nPICKUPS\n87")
        }
    }

    @Test func missingPickupsIsNil() throws {
        #expect(try SnapshotParser.parse("SCREEN TIME\n20 min").pickups == nil)
    }

    @Test func failsWithoutScreenTimeLabel() {
        #expect(throws: SnapshotParseError.screenTimeNotFound) {
            try SnapshotParser.parse("PICKUPS\n87")
        }
    }
}
