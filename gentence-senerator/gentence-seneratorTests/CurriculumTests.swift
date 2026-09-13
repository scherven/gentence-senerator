import Testing
import Foundation
@testable import gentence_senerator

/// The curriculum is data now, and data that never reaches the bundle fails
/// silently: `pickStretch` finds nothing, no level ever offers a structure, and
/// the app looks like it is working. Nothing else in the app notices, so this
/// is the thing that has to.
struct CurriculumTests {

    /// Below this a language has a level or two of points and a ceiling the
    /// learner hits in a week. Well under the 137 that actually ship, so an
    /// author trimming a file does not trip it — only a file that went missing.
    static let floor = 100

    @Test func theShippedCurriculumLoads() {
        for language in Language.allCases {
            let pack = LanguagePacks.pack(for: language)
            #expect(pack.points.count >= CurriculumTests.floor)
        }
    }

    /// A level with no points is a learner sitting at it with nothing to reach
    /// for, and the record on the plan screen showing them an empty band.
    @Test func everyLevelHasSomethingAtIt() {
        for language in Language.allCases {
            let pack = LanguagePacks.pack(for: language)
            for level in 1...pack.levels {
                #expect(pack.points.contains { $0.level == level },
                        "\(language.rawValue) has nothing at level \(level)")
            }
        }
    }

    /// Ids are what scheduling and reach key on, so a duplicate silently merges
    /// two points' histories.
    @Test func idsAreUnique() {
        for language in Language.allCases {
            let pack = LanguagePacks.pack(for: language)
            #expect(pack.pointIDs.count == pack.points.count)
        }
    }

    /// A point whose kind the assessor may not return can never be linked to an
    /// attempt, so it is reached for and then never credited.
    @Test func everyPointUsesAKindItsPackAllows() {
        for language in Language.allCases {
            let pack = LanguagePacks.pack(for: language)
            let allowed = Set(pack.kinds)
            for point in pack.points {
                #expect(allowed.contains(point.kind),
                        "\(language.rawValue)/\(point.id) uses \(point.kind.rawValue)")
            }
        }
    }

    /// An empty bundle is an empty curriculum, not a crash and not a throw.
    @Test func aMissingFileFailsSoft() {
        let none = Curriculum(bundle: Bundle(for: Marker.self))
        #expect(none.isEmpty)
        #expect(none.points(for: .mandarin).isEmpty)
    }

    /// Only to give `Bundle(for:)` something with no resources in it.
    private final class Marker {}
}
