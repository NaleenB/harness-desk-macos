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

if failures == 0 {
    print("pricing: \(cases.count) boundary cases passed")
    print("token URL: \(tokenCases.count) cases passed")
}
exit(failures == 0 ? 0 : 1)
