import Testing
import UIKit
@testable import gentence_senerator

/// Faces follow the system text size, unchanged at the default.
@MainActor
struct TypeScaleTests {

    @Test func theDefaultSizeIsUnchanged() {
        for size in [10, 11, 13, 14.5, 16, 17, 20, 22, 26, 36] as [CGFloat] {
            #expect(abs(Theme.F.scaled(size, mono: true, category: .large) - size) < 0.01)
            #expect(abs(Theme.F.scaled(size, mono: false, category: .large) - size) < 0.01)
        }
    }

    @Test func proseGrowsAndLabelsStopAtTheirCap() {
        let big = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        #expect(Theme.F.scaled(16, mono: false, category: big) > 32)
        #expect(Theme.F.scaled(11, mono: true, category: big) <= 22)
        #expect(Theme.F.scaled(36, mono: true, category: big) <= 36 * 1.4 + 0.01)
        #expect(Theme.F.scaled(11, mono: true, upTo: 1.4, category: big) <= 11 * 1.4 + 0.01)
        #expect(Theme.F.scaled(16, mono: false, category: .extraSmall) < 16)
    }
}
