import XCTest
@testable import PolyfenceCore

/**
 * Swift mirror of the Kotlin `NotificationTextTest`: the placeholder renderer,
 * the defaults, and the places a config field has to appear before a host can
 * actually use it.
 *
 * That last part is the point of this file. `PolyfenceConfig` persists these, so
 * storage and the read path alone make the feature look finished: the strings
 * are there, the alert picks them up, and every foreground test passes. It stays
 * broken for every bridge consumer until `updateConfigurationFromMap` can write
 * them, `getCurrentConfigurationMap` can read them back, and
 * `resetSmartConfiguration` can restore them. Those three are asserted here so
 * removing any one of them turns this file red.
 *
 * Assertions must match Kotlin field for field: both platforms feed the same
 * TypeScript and Dart consumers, so a divergence here is a real bug.
 */
class NotificationTextTests: XCTestCase {

    private var cfg: PolyfenceConfig!

    override func setUp() {
        super.setUp()
        cfg = PolyfenceConfig()
        // UserDefaults is process-wide, so a previous test's writes would read
        // as this test's starting state.
        LocationTracker.resetNotificationText()
    }

    override func tearDown() {
        LocationTracker.resetNotificationText()
        super.tearDown()
    }

    private func notificationText(of map: [String: Any]) -> [String: Any] {
        return map["notificationText"] as? [String: Any] ?? [:]
    }

    // MARK: - The placeholder renderer

    func testRendersTheZoneNameIntoTheSlot() {
        XCTAssertEqual(
            "Entered Home",
            LocationTracker.renderNotificationText("Entered {zone}", ["zone": "Home"])
        )
    }

    func testRendersATemplateThatPutsTheSlotFirst() {
        // The reason substitution is used instead of a fixed prefix: a host
        // writing in a language that leads with the place has to be able to.
        XCTAssertEqual(
            "Home: arrived",
            LocationTracker.renderNotificationText("{zone}: arrived", ["zone": "Home"])
        )
    }

    func testRendersATemplateWithNoSlotAtAll() {
        // A host that wants the same line regardless of zone is making a choice
        // about its own copy, not a mistake.
        XCTAssertEqual(
            "You arrived",
            LocationTracker.renderNotificationText("You arrived", ["zone": "Home"])
        )
    }

    func testRendersEveryOccurrenceWhenASlotRepeats() {
        XCTAssertEqual(
            "Home, welcome to Home",
            LocationTracker.renderNotificationText(
                "{zone}, welcome to {zone}",
                ["zone": "Home"]
            )
        )
    }

    func testLeavesAPlaceholderItHasNoValueForExactlyAsWritten() {
        // Blanking it would turn a host's typo into a sentence with a hole in
        // it. Left visible, the tray shows which line needs fixing.
        XCTAssertEqual(
            "Entered Home ({whatver})",
            LocationTracker.renderNotificationText(
                "Entered {zone} ({whatver})",
                ["zone": "Home"]
            )
        )
    }

    func testRendersHoursAndMinutesIndependently() {
        XCTAssertEqual(
            "2h 30min",
            LocationTracker.renderNotificationText(
                "{hours}h {minutes}min",
                ["hours": "2", "minutes": "30"]
            )
        )
    }

    // MARK: - Defaults: a host that sets nothing sees no change

    func testAnUnconfiguredHostReadsTodaysExactEnglish() {
        XCTAssertEqual("Polyfence Active", cfg.trackingNotificationTitle)
        XCTAssertEqual("Monitoring geofence zones", cfg.trackingNotificationText)
        XCTAssertNil(cfg.trackingNotificationIconName)
        XCTAssertEqual("Entered {zone}", cfg.alertTitleEnter)
        XCTAssertEqual("Dwelling in {zone}", cfg.alertTitleDwell)
        XCTAssertEqual("Exited {zone}", cfg.alertTitleExit)
        XCTAssertEqual("Here under a minute", cfg.alertDwellBodyUnderMinute)
        XCTAssertEqual("Here {minutes} min", cfg.alertDwellBodyMinutes)
        XCTAssertEqual("Here {hours}h", cfg.alertDwellBodyHours)
        XCTAssertEqual("Here {hours}h {minutes} min", cfg.alertDwellBodyHoursMinutes)
    }

    func testTheUnconfiguredDefaultsRenderToTheStringsThisChangeReplaced() {
        // Belt and braces on the one promise that matters to an existing
        // integrator: upgrade, set nothing, see byte-identical text.
        let zone = ["zone": "Home"]
        XCTAssertEqual(
            "Entered Home",
            LocationTracker.renderNotificationText(cfg.alertTitleEnter, zone)
        )
        XCTAssertEqual(
            "Dwelling in Home",
            LocationTracker.renderNotificationText(cfg.alertTitleDwell, zone)
        )
        XCTAssertEqual(
            "Exited Home",
            LocationTracker.renderNotificationText(cfg.alertTitleExit, zone)
        )
        XCTAssertEqual(
            "Here 5 min",
            LocationTracker.renderNotificationText(
                cfg.alertDwellBodyMinutes,
                ["minutes": "5"]
            )
        )
        XCTAssertEqual(
            "Here 2h",
            LocationTracker.renderNotificationText(cfg.alertDwellBodyHours, ["hours": "2"])
        )
        XCTAssertEqual(
            "Here 2h 30 min",
            LocationTracker.renderNotificationText(
                cfg.alertDwellBodyHoursMinutes,
                ["hours": "2", "minutes": "30"]
            )
        )
    }

    // MARK: - The write path

    func testUpdateConfigurationWritesNotificationTextAHostSets() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "notificationText": [
                "trackingTitle": "Roadie",
                "enterTitle": "Arrivé à {zone}",
                "dwellBodyMinutes": "{minutes} minutes ici"
            ]
        ])

        XCTAssertEqual("Roadie", cfg.trackingNotificationTitle)
        XCTAssertEqual("Arrivé à {zone}", cfg.alertTitleEnter)
        XCTAssertEqual("{minutes} minutes ici", cfg.alertDwellBodyMinutes)
    }

    func testAPartialWriteLeavesTheKeysItDidNotMentionAlone() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "notificationText": ["enterTitle": "Arrivé à {zone}"]
        ])

        XCTAssertEqual("Arrivé à {zone}", cfg.alertTitleEnter)
        XCTAssertEqual("Exited {zone}", cfg.alertTitleExit)
        XCTAssertEqual("Polyfence Active", cfg.trackingNotificationTitle)
    }

    func testAnIllTypedValueIsIgnoredRatherThanStored() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["notificationText": ["enterTitle": 42]])
        XCTAssertEqual("Entered {zone}", cfg.alertTitleEnter)
    }

    func testAConfigMapWithNoNotificationTextKeyChangesNothing() {
        cfg.alertTitleEnter = "Arrivé à {zone}"
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["enableDebugLogging": true])
        XCTAssertEqual("Arrivé à {zone}", cfg.alertTitleEnter)
    }

    // MARK: - Read-back

    func testGetConfigurationEmitsTheTextAHostSet() {
        cfg.alertTitleEnter = "Arrivé à {zone}"

        let tracker = LocationTracker()
        let emitted = notificationText(of: tracker.getCurrentConfigurationMap())
        XCTAssertEqual("Arrivé à {zone}", emitted["enterTitle"] as? String)
    }

    func testAnUnsetIconNameIsAbsentRatherThanNull() {
        // The map crosses a bridge that cannot carry a null.
        let tracker = LocationTracker()
        let emitted = notificationText(of: tracker.getCurrentConfigurationMap())
        XCTAssertNil(emitted["trackingIconName"])
    }

    func testARoundTripThroughGetConfigurationDoesNotResetTheHostsWording() {
        // The failure this guards: read the config into a cache, write the cache
        // back, and wording the host set earlier is silently replaced by ours.
        cfg.alertTitleEnter = "Arrivé à {zone}"

        let tracker = LocationTracker()
        let readBack = tracker.getCurrentConfigurationMap()
        tracker.updateConfigurationFromMap(readBack)

        XCTAssertEqual("Arrivé à {zone}", cfg.alertTitleEnter)
    }

    // MARK: - Reset

    func testResetSmartConfigurationRestoresTheDefaultTextOverAHostsWording() {
        cfg.alertTitleEnter = "Arrivé à {zone}"
        cfg.trackingNotificationTitle = "Roadie"

        let tracker = LocationTracker()
        tracker.resetSmartConfiguration()

        XCTAssertEqual("Entered {zone}", cfg.alertTitleEnter)
        XCTAssertEqual("Polyfence Active", cfg.trackingNotificationTitle)
    }

    // MARK: - The renderer must not rescan what it just inserted

    func testAZoneNameThatContainsAPlaceholderIsNotSubstitutedAgain() {
        // A zone can legitimately be called "Bay {minutes}". Replacing slots one
        // at a time in the running result would rescan the name just inserted and
        // turn the host's own text into a number. On Swift it would also depend on
        // Dictionary iteration order, which is not defined, so the same zone could
        // render differently between runs and differently from Android.
        XCTAssertEqual(
            "In Bay {minutes} for 12 min",
            LocationTracker.renderNotificationText(
                "In {zone} for {minutes} min",
                ["zone": "Bay {minutes}", "hours": "2", "minutes": "12"]
            )
        )
    }

    func testAReplacementThatLooksLikeAnotherSlotIsLeftAlone() {
        XCTAssertEqual(
            "{hours}",
            LocationTracker.renderNotificationText("{zone}", ["zone": "{hours}", "hours": "9"])
        )
    }

    func testAnUnterminatedBraceIsLeftExactlyAsWritten() {
        XCTAssertEqual(
            "Entered {zone",
            LocationTracker.renderNotificationText("Entered {zone", ["zone": "Home"])
        )
    }

    func testAnEmptyBracePairIsLeftExactlyAsWritten() {
        XCTAssertEqual(
            "Entered {} now",
            LocationTracker.renderNotificationText("Entered {} now", ["zone": "Home"])
        )
    }

    func testTextAfterTheLastSlotSurvives() {
        XCTAssertEqual(
            "a Home b",
            LocationTracker.renderNotificationText("a {zone} b", ["zone": "Home"])
        )
    }

    func testRenderingIsStableAcrossRepeatedCalls() {
        // Dictionary order varies per process on Swift. A rescanning renderer
        // could pass once and fail later, so assert the same answer many times
        // over a template where order would have mattered.
        for _ in 0..<200 {
            XCTAssertEqual(
                "In Bay {minutes} for 12 min",
                LocationTracker.renderNotificationText(
                    "In {zone} for {minutes} min",
                    ["zone": "Bay {minutes}", "hours": "2", "minutes": "12"]
                )
            )
        }
    }

    // MARK: - Reset has to be able to clear the icon

    func testResetClearsAHostSetIcon() {
        cfg.trackingNotificationIconName = "ic_tracking"

        let tracker = LocationTracker()
        tracker.resetSmartConfiguration()

        XCTAssertNil(cfg.trackingNotificationIconName)
    }

    func testAnEmptyIconNameClearsAHostSetIcon() {
        // The read map omits this key when unset, so a reset payload cannot say
        // "no icon" by omission the way it can for the nine sentences. An empty
        // string is the value that means cleared, and Android applies the same
        // rule so a reset clears the icon on both platforms.
        cfg.trackingNotificationIconName = "ic_tracking"

        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "notificationText": ["trackingIconName": ""]
        ])

        XCTAssertNil(cfg.trackingNotificationIconName)
    }

    func testAPartialWriteThatOmitsTheIconLeavesItAlone() {
        // Omission means "leave what is stored alone", which is what every other
        // partial update does. Only an explicit empty value clears.
        cfg.trackingNotificationIconName = "ic_tracking"

        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "notificationText": ["trackingTitle": "Roadie"]
        ])

        XCTAssertEqual("ic_tracking", cfg.trackingNotificationIconName)
    }

    func testGetConfigurationOmitsTheIconKeyAgainAfterAReset() {
        cfg.trackingNotificationIconName = "ic_tracking"

        let tracker = LocationTracker()
        tracker.resetSmartConfiguration()

        let emitted = notificationText(of: tracker.getCurrentConfigurationMap())
        XCTAssertNil(emitted["trackingIconName"])
    }

    func testAnEmptyOrAsciiWhitespaceIconNameReadsAsUnset() {
        // The rule is spelled out rather than borrowed, because the obvious
        // predicate on each platform disagrees with the other: Foundation's
        // whitespacesAndNewlines counts U+0085 and not U+001C to U+001F,
        // Kotlin's isBlank the reverse. The same table runs on Android.
        for empty in ["", " ", "   ", "\t", "\n", "\r", "\r\n", " \n ",
                      "\u{000B}", "\u{000C}", " \t\r\n "] {
            cfg.trackingNotificationIconName = empty
            XCTAssertNil(
                cfg.trackingNotificationIconName,
                "\(Array(empty.unicodeScalars.map { $0.value })) must read as unset"
            )
        }
    }

    func testAnythingOutsideAsciiWhitespaceIsKeptAsAName() {
        // Including the separators and exotic spaces the two platforms disagree
        // about. A drawable cannot be named with them, so the resolver falls
        // back visibly rather than the SDK discarding what the host set.
        for kept in ["\u{0085}", "\u{00A0}", "\u{2028}", "\u{2029}", "\u{3000}",
                     "\u{001C}", "ic_x"] {
            cfg.trackingNotificationIconName = kept
            XCTAssertEqual(
                kept,
                cfg.trackingNotificationIconName,
                "\(Array(kept.unicodeScalars.map { $0.value })) must be kept"
            )
        }
    }

    // MARK: - Channel labels, which exist on Android and round-trip here

    func testAnUnconfiguredHostReadsTodaysChannelLabels() {
        XCTAssertEqual("Location Tracking", cfg.trackingChannelName)
        XCTAssertEqual("Background location tracking", cfg.trackingChannelDescription)
        XCTAssertEqual("Geofence Alerts", cfg.alertChannelName)
        XCTAssertEqual("Zone entry and exit notifications", cfg.alertChannelDescription)
    }

    func testUpdateConfigurationStoresChannelLabels() {
        // iOS has no notification channels: its categories carry identifiers the
        // user never sees. These are stored and echoed so a cross-platform host
        // can round-trip one configuration object through either platform
        // without the iOS read dropping the keys its Android build uses.
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "notificationText": [
                "trackingChannelName": "Suivi de position",
                "alertChannelName": "Alertes de zone"
            ]
        ])

        XCTAssertEqual("Suivi de position", cfg.trackingChannelName)
        XCTAssertEqual("Alertes de zone", cfg.alertChannelName)
    }

    func testGetConfigurationEmitsTheChannelLabels() {
        cfg.alertChannelName = "Alertes de zone"

        let tracker = LocationTracker()
        let emitted = notificationText(of: tracker.getCurrentConfigurationMap())
        XCTAssertEqual("Alertes de zone", emitted["alertChannelName"] as? String)
    }

    func testResetRestoresTheDefaultChannelLabels() {
        cfg.alertChannelName = "Alertes de zone"
        cfg.trackingChannelDescription = "Suivi en arrière-plan"

        let tracker = LocationTracker()
        tracker.resetSmartConfiguration()

        XCTAssertEqual("Geofence Alerts", cfg.alertChannelName)
        XCTAssertEqual("Background location tracking", cfg.trackingChannelDescription)
    }

    func testARoundTripDoesNotResetTheHostsChannelLabels() {
        cfg.alertChannelName = "Alertes de zone"

        let tracker = LocationTracker()
        let readBack = tracker.getCurrentConfigurationMap()
        tracker.updateConfigurationFromMap(readBack)

        XCTAssertEqual("Alertes de zone", cfg.alertChannelName)
    }

    func testTheGroupEmitsExactlyTheDocumentedKeys() {
        // The exact set rather than the count, matching Kotlin. A count catches
        // a key dropped from the read side but not one renamed there, and a
        // rename is the same defect from a caller's point of view: the value it
        // set never comes back. Asserting the same set on both platforms is also
        // what stops them drifting apart, since one object crosses both bridges.
        cfg.trackingNotificationIconName = "ic_tracking"

        let tracker = LocationTracker()
        let emitted = notificationText(of: tracker.getCurrentConfigurationMap())
        XCTAssertEqual(
            Set([
                "trackingTitle",
                "trackingText",
                "trackingIconName",
                "enterTitle",
                "dwellTitle",
                "exitTitle",
                "dwellBodyUnderMinute",
                "dwellBodyMinutes",
                "dwellBodyHours",
                "dwellBodyHoursMinutes",
                "trackingChannelName",
                "trackingChannelDescription",
                "alertChannelName",
                "alertChannelDescription"
            ]),
            Set(emitted.keys)
        )
    }

    // MARK: - Which dwell body applies, and with what numbers

    func testTheDwellBodyTableHoldsAtEveryBoundary() {
        // A four-way branch plus a total-versus-remainder switch, and the whole
        // thing had no coverage because formatDwellBody needs a live engine.
        // Same table as Kotlin's.
        let cases: [(Int, LocationTracker.DwellBodyVariant, Int, Int)] = [
            (-5, .underMinute, 0, 0),
            (0, .underMinute, 0, 0),
            (1, .minutes, 0, 1),
            (59, .minutes, 0, 59),
            (60, .hours, 1, 0),
            (61, .hoursMinutes, 1, 1),
            (119, .hoursMinutes, 1, 59),
            (120, .hours, 2, 0),
            (121, .hoursMinutes, 2, 1),
            (1440, .hours, 24, 0),
        ]

        for (totalMinutes, variant, hours, minutes) in cases {
            let selection = LocationTracker.selectDwellBody(totalMinutes)
            XCTAssertEqual(variant, selection.variant, "variant at \(totalMinutes)")
            XCTAssertEqual(hours, selection.hours, "hours at \(totalMinutes)")
            XCTAssertEqual(minutes, selection.minutes, "minutes at \(totalMinutes)")
        }
    }

    func testANegativeDurationNeverReachesAHostsSentence() {
        let selection = LocationTracker.selectDwellBody(-1)
        XCTAssertEqual(0, selection.hours)
        XCTAssertEqual(0, selection.minutes)
        XCTAssertEqual(.underMinute, selection.variant)
    }

    func testTheUnderAnHourBodyIsHandedTheWholeDurationNotTheRemainder() {
        XCTAssertEqual(42, LocationTracker.selectDwellBody(42).minutes)
    }

    // MARK: - The renderer over awkward scalars

    func testACombiningMarkAfterABraceDoesNotAbandonTheRestOfTheTemplate() {
        // Scanning Characters made "}" plus a combining mark one grapheme that
        // did not equal "}", so the search missed and every remaining slot went
        // unrendered. Kotlin walks code units and substitutes normally.
        XCTAssertEqual(
            "Home\u{0301} for 12 min",
            LocationTracker.renderNotificationText(
                "{zone}\u{0301} for {minutes} min",
                ["zone": "Home", "minutes": "12"]
            )
        )
    }

    func testAnEmojiInTheTemplateAndInTheReplacementBothSurvive() {
        XCTAssertEqual(
            "🚀 Casa 🏠 now",
            LocationTracker.renderNotificationText(
                "🚀 {zone} now",
                ["zone": "Casa 🏠"]
            )
        )
    }
}
