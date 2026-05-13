import XCTest
@testable import watchCat

final class URLUtilitiesTests: XCTestCase {
    func test_domain_basics() {
        XCTAssertEqual(URLUtilities.domain(from: "https://github.com/groue/GRDB.swift"), "github.com")
        XCTAssertEqual(URLUtilities.domain(from: "http://Example.COM/x"), "example.com")
    }

    func test_domain_stripsLeadingWWW() {
        XCTAssertEqual(URLUtilities.domain(from: "https://www.apple.com/mac/"), "apple.com")
    }

    func test_domain_preservesSubdomains() {
        XCTAssertEqual(URLUtilities.domain(from: "https://docs.swift.org/"), "docs.swift.org")
    }

    func test_domain_returnsNilForNonHTTP() {
        XCTAssertNil(URLUtilities.domain(from: "chrome://newtab"))
        XCTAssertNil(URLUtilities.domain(from: ""))
        XCTAssertNil(URLUtilities.domain(from: "not a url"))
    }

    func test_stripQuery_removesQueryButKeepsFragment() {
        XCTAssertEqual(
            URLUtilities.stripQuery(from: "https://github.com/search?q=swift&page=2#results"),
            "https://github.com/search#results"
        )
    }

    func test_stripQuery_idempotentWhenNoQuery() {
        XCTAssertEqual(
            URLUtilities.stripQuery(from: "https://github.com/swift"),
            "https://github.com/swift"
        )
    }

    func test_bucketKey_domainUnit() {
        let key = URLUtilities.bucketKey(
            url: "https://news.ycombinator.com/item?id=1", title: "HN",
            isIncognito: false, unit: .domain
        )
        XCTAssertEqual(key, "news.ycombinator.com")
    }

    func test_bucketKey_urlUnit_stripsQuery() {
        let key = URLUtilities.bucketKey(
            url: "https://example.com/path?a=1", title: "T",
            isIncognito: false, unit: .url, stripQuery: true
        )
        XCTAssertEqual(key, "https://example.com/path")
    }

    func test_bucketKey_urlUnit_keepsQueryWhenDisabled() {
        let key = URLUtilities.bucketKey(
            url: "https://example.com/path?a=1", title: "T",
            isIncognito: false, unit: .url, stripQuery: false
        )
        XCTAssertEqual(key, "https://example.com/path?a=1")
    }

    func test_bucketKey_titleUnit() {
        let key = URLUtilities.bucketKey(
            url: "https://example.com/", title: "Example Domain",
            isIncognito: false, unit: .title
        )
        XCTAssertEqual(key, "Example Domain")
    }

    // SPEC §F3.5.1 — incognito defaults to a single bucket; opt-in exposes the domain.
    func test_bucketKey_incognito_defaultsToBucketLabel() {
        let key = URLUtilities.bucketKey(
            url: "https://secret.example.com", title: "x", isIncognito: true,
            unit: .domain, recordIncognitoDomain: false
        )
        XCTAssertEqual(key, URLUtilities.incognitoBucket)
    }

    func test_bucketKey_incognito_optInExposesDomain() {
        let key = URLUtilities.bucketKey(
            url: "https://secret.example.com", title: "x", isIncognito: true,
            unit: .domain, recordIncognitoDomain: true
        )
        XCTAssertEqual(key, "secret.example.com")
    }
}
