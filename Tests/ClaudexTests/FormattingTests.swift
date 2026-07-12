import Foundation
import Testing
@testable import Claudex

@Suite struct FormattingTests {
    private let now = Date(timeIntervalSince1970: 0)

    @Test func relativeFutureUsesCompactTwoPartDuration() {
        let date = now.addingTimeInterval((2 * 86_400) + (3 * 3_600) + (20 * 60))
        #expect(Fmt.relativeFuture(date, now: now) == "2d 3h")
    }

    @Test func relativeFutureHandlesExpiredAndSubMinuteDates() {
        #expect(Fmt.relativeFuture(now.addingTimeInterval(-1), now: now) == "now")
        #expect(Fmt.relativeFuture(now.addingTimeInterval(30), now: now) == "<1m")
    }

    @Test func shortUntilUsesLargestUnit() {
        #expect(Fmt.shortUntil(now.addingTimeInterval(90), now: now) == "1m")
        #expect(Fmt.shortUntil(now.addingTimeInterval(3_600), now: now) == "1h")
        #expect(Fmt.shortUntil(now.addingTimeInterval(86_400), now: now) == "1d")
    }

    @Test func relativePastHasStableBoundaries() {
        #expect(Fmt.relativePast(nil, now: now) == "never")
        #expect(Fmt.relativePast(now.addingTimeInterval(-3), now: now) == "just now")
        #expect(Fmt.relativePast(now.addingTimeInterval(-45), now: now) == "45s ago")
        #expect(Fmt.relativePast(now.addingTimeInterval(-3_900), now: now) == "1h 5m ago")
    }
}
