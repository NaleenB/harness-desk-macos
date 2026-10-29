import Foundation

let formatter = ISO8601DateFormatter()
let cases: [(String, Bool)] = [
    ("2026-10-26T00:59:00Z", false),
    ("2026-10-26T01:00:00Z", true),
    ("2026-10-26T03:59:00Z", true),
    ("2026-10-26T04:00:00Z", false),
    ("2026-10-26T05:59:00Z", false),
    ("2026-10-26T06:00:00Z", true),
    ("2026-10-26T09:59:00Z", true),
    ("2026-10-26T10:00:00Z", false),
    ("2026-10-25T02:00:00Z", false), // Sunday
    ("2026-10-24T06:00:00Z", false), // Saturday
]

var failures = 0
for (iso, expected) in cases {
    guard let date = formatter.date(from: iso) else {
        print("FAIL \(iso): unparseable")
        failures += 1
        continue
    }
    let actual = Pricing.isPeak(at: date)
    if actual != expected {
        print("FAIL \(iso): expected \(expected), got \(actual)")
        failures += 1
    }
}

let tokenCases: [(String, Int, Bool)] = [
    ("http://127.0.0.1:3080/?token=abc\n", 3080, true),
    ("http://localhost:3080/?token=abc", 3080, true),
    ("http://127.0.0.1:3081/?token=abc", 3080, false),
    ("http://example.com:3080/?token=abc", 3080, false),
    ("https://127.0.0.1:3080/?token=abc", 3080, false),
    ("not a url", 3080, false),
]
for (text, port, expected) in tokenCases {
    let actual = TokenURL.parse(text, port: port) != nil
    if actual != expected {
        print("FAIL token URL \(text): expected \(expected), got \(actual)")
        failures += 1
    }
}

let transitionCases: [(String, String, String)] = [
    ("2026-10-26T02:00:00Z", "2026-10-26T04:00:00Z", "2h 0m"),
    ("2026-10-26T00:30:00Z", "2026-10-26T01:00:00Z", "0h 30m"),
    ("2026-10-26T05:00:00Z", "2026-10-26T06:00:00Z", "1h 0m"),
    ("2026-10-26T09:00:00Z", "2026-10-26T10:00:00Z", "1h 0m"),
    ("2026-10-26T12:00:00Z", "2026-10-27T01:00:00Z", "13h 0m"),
    ("2026-10-26T04:00:00Z", "2026-10-26T06:00:00Z", "2h 0m"), // exact boundary
    ("2026-10-26T10:00:00Z", "2026-10-27T01:00:00Z", "15h 0m"),
    ("2026-10-26T03:59:30Z", "2026-10-26T04:00:00Z", "0h 1m"), // rounds up
    ("2026-10-25T02:00:00Z", "2026-10-26T01:00:00Z", "23h 0m"), // Sunday
    ("2026-10-30T12:00:00Z", "2026-11-02T01:00:00Z", "2d 13h 0m"), // Friday→Monday
    ("2026-10-31T12:00:00Z", "2026-11-02T01:00:00Z", "1d 13h 0m"), // Saturday
]
for (startISO, endISO, expected) in transitionCases {
    guard let start = formatter.date(from: startISO), let expectedEnd = formatter.date(from: endISO) else {
        print("FAIL transition \(startISO): unparseable")
        failures += 1
        continue
    }
    guard let end = Pricing.nextTransition(after: start) else {
        print("FAIL transition \(startISO): no transition found")
        failures += 1
        continue
    }
    if end != expectedEnd {
        print("FAIL transition \(startISO): expected \(endISO), got \(formatter.string(from: end))")
        failures += 1
        continue
    }
    let text = Pricing.remainingText(from: start, to: end)
    if text != expected {
        print("FAIL remaining \(startISO): expected \(expected), got \(text)")
        failures += 1
    }
}

let versionCases: [(String, String, ComparisonResult)] = [
    ("0.1.4", "0.1.4", .orderedSame),
    ("v0.1.4", "0.1.4", .orderedSame),
    ("0.1.10", "0.1.9", .orderedDescending),
    ("1.0", "1.0.0", .orderedSame),
    ("0.2.1-rc.2", "0.2.1-rc.4", .orderedAscending),
    ("0.2.1-rc.4", "0.2.1-rc.2", .orderedDescending),
    ("0.2.1", "0.2.1-rc.4", .orderedDescending),
    ("0.2.2-alpha.2", "0.2.1-rc.4", .orderedDescending),
    ("0.2.1+build.5", "0.2.1", .orderedSame),
    ("0.2.1-rc.10", "0.2.1-rc.9", .orderedDescending),
    ("1.0.0-alpha.1", "1.0.0-alpha.beta", .orderedAscending),
    ("1.0.0-beta.11", "1.0.0-beta.2", .orderedDescending),
]
for (left, right, expected) in versionCases {
    let actual = VersionOrder.compare(left, right)
    if actual != expected {
        print("FAIL version \(left) vs \(right): expected \(expected.rawValue), got \(actual.rawValue)")
        failures += 1
    }
}
if VersionOrder.isNewer("0.2.1-rc.4", than: "0.2.1-rc.2") != true {
    print("FAIL isNewer forward")
    failures += 1
}
if VersionOrder.isNewer("0.2.1-rc.2", than: "0.2.1-rc.4") != false {
    print("FAIL isNewer backward")
    failures += 1
}

let tagCases: [(String, [String: String]?)] = [
    ("{\"latest\":\"0.2.1-rc.2\",\"next\":\"0.2.1-rc.4\"}", ["latest": "0.2.1-rc.2", "next": "0.2.1-rc.4"]),
    ("{\"next\":\"0.2.1-rc.4\"}", nil),
    ("[]", nil),
]
for (json, expected) in tagCases {
    let parsed = try? UpdateFeed.parseDistTags(Data(json.utf8))
    if parsed != expected {
        print("FAIL dist-tags \(json): got \(String(describing: parsed))")
        failures += 1
    }
}

let releaseCases: [(String, String?)] = [
    ("{\"tag_name\":\"v0.1.4\"}", "0.1.4"),
    ("{\"tag_name\":\"0.1.4\"}", "0.1.4"),
    ("{\"name\":\"no tag\"}", nil),
    ("not json", nil),
]
for (json, expected) in releaseCases {
    let parsed = try? UpdateFeed.parseLatestReleaseTag(Data(json.utf8))
    if parsed != expected {
        print("FAIL release tag \(json): got \(String(describing: parsed))")
        failures += 1
    }
}

if failures == 0 {
    print("pricing: \(cases.count) boundary cases passed")
    print("transitions: \(transitionCases.count) cases passed")
    print("token URL: \(tokenCases.count) cases passed")
    print("versions: \(versionCases.count) cases passed")
}
exit(failures == 0 ? 0 : 1)
