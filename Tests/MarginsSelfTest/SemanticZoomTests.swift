import Foundation
@testable import MarginsCore

func runSemanticZoomTests() {
    test("semantic zoom stops and budgets") {
        check(SemanticZoomStop.allCases.map(\.rawValue) == [100, 75, 50, 25, 10], "five ordered length stops")
        check(SemanticZoomStop.nearest(to: 63) == .tight, "nearest stop")
        check(SemanticZoomStop.nearest(to: 62) == .half, "snap below midpoint")
        check(SemanticZoomStop.nearest(to: .nan) == .full, "nonfinite slider input is safe")
        check(SemanticZoomStop.full.longer == .full && SemanticZoomStop.executive.shorter == .executive,
              "stepping clamps at endpoints")
        check(SemanticZoomStop.full.shorter == .tight && SemanticZoomStop.brief.longer == .half, "adjacent steps")
        check(SemanticZoomStop.tight.targetWords(sourceWords: 202) == 152, "round concrete word budget")
        check(SemanticZoomStop.executive.targetWords(sourceWords: -2) == 0, "negative count clamped")
        check(!SemanticZoomStop.canSummarize(wordCount: 199), "short document threshold")
        check(SemanticZoomStop.canSummarize(wordCount: 200), "threshold is inclusive")
    }
    test("semantic zoom live prose count") {
        let html = """
        <h1>Live heading</h1><p>A <span class="chg"><del>deleted old words</del>
        <ins>new words</ins></span> remain.</p><p class="diff-removed">removed block</p>
        <pre>many code words</pre><table><tr><td>table words</td></tr></table>
        <figure><figcaption>figure caption</figcaption><img alt="image description"></figure>
        <p>Don’t double-count &amp; entities&nbsp;here.</p>
        """
        check(SemanticZoom.liveWordCount(in: html) == 10, "headings and inserted prose count; removed and nonprose do not")
        check(SemanticZoom.liveWordCount(in: "<p>one<strong>two</strong>three</p>") == 3, "inline boundaries")
        check(SemanticZoom.liveWordCount(in: "<p>你好 café 42</p>") == 3, "Unicode prose and numbers")
        check(SemanticZoom.liveWordCount(in: "") == 0, "empty source")
        check(SemanticZoom.liveWordCount(in: "<p>bad <") == 0, "malformed source fails closed")
        check(SemanticZoom.documentHash(for: "") ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "canonical HTML hash is SHA256")
        check(SemanticZoom.documentHash(for: "<p>a</p>") != SemanticZoom.documentHash(for: "<p>b</p>"),
              "source edit changes cache identity")
    }
    test("semantic zoom stop-specific prompt") {
        let source = "<h1 data-bid=\"b1\">Title</h1><p data-bid=\"b2\">"
            + Array(repeating: "word", count: 999).joined(separator: " ") + "</p>"
        for stop in SemanticZoomStop.allCases {
            let prompt = SemanticZoomPromptBuilder.prompt(html: source, stop: stop)
            check(prompt.contains("Target ~\(stop.targetWords(sourceWords: 1000)) words out of 1000"),
                  "concrete target at \(stop.rawValue)%")
            check(prompt.contains("data-bid=\"b1\"") && prompt.contains("data-source-block=\"bN\""), "source anchor guidance")
            check(prompt.contains("margins-asset://") && prompt.contains("clean semantic HTML"), "assets and clean output")
        }
        let tracked = "<p data-bid=\"b2\"><span class=\"chg\"><del>OUTDATED</del><ins>LIVE</ins></span></p>"
        let prompt = SemanticZoomPromptBuilder.prompt(html: tracked, stop: .half)
        check(!prompt.contains("OUTDATED") && prompt.contains("LIVE") && !prompt.contains("<ins>"), "clean live source")
        check(prompt.contains("Keep key diagrams") && prompt.contains("h1/h2"), "half preserves structure")
        let brief = SemanticZoomPromptBuilder.prompt(html: source, stop: .brief)
        check(brief.contains("Omit code blocks") && brief.contains("h1/h2"), "brief keeps headings but omits secondary nonprose")
        check(SemanticZoomPromptBuilder.prompt(html: source, stop: .executive).contains("key conclusions, and decisions"),
              "executive captures conclusions")
    }
    test("semantic zoom HTML allowlist and promotion") {
        let html = """
        <h2 data-source-block="b2" data-bid="b9" class="size-zoomed">Heading</h2>
        <p data-other="discard">A <strong>clean</strong> &amp; safe summary.</p>
        <img src="margins-asset://img/abcdef.png" alt="Diagram"/>
        <a href="https://example.com/?a=1&amp;b=2">Link</a>
        """
        let clean = try SemanticZoomHTMLSanitizer.sanitize(html)
        check(clean.contains("data-source-block=\"b2\"") && clean.contains("margins-asset://img/abcdef.png"), "anchors and assets retained")
        check(!clean.contains("class=") && !clean.contains("data-other"), "transient editor attributes stripped")
        check(clean.contains("a=1&amp;b=2"), "safe query entities retained")
        let promoted = try SemanticZoomHTMLSanitizer.sanitize(html, forPromotion: true)
        check(!promoted.contains("data-source") && !promoted.contains("data-bid"), "promotion strips transient source IDs")
        check(promoted.contains("<strong>clean</strong>"), "promotion preserves semantic formatting")
        let document = MarginsDocument(html: "<p>Canonical full source</p>")
        _ = try SemanticZoomHTMLSanitizer.sanitize(html)
        check(document.html == "<p>Canonical full source</p>", "generating a summary never mutates canonical document")
    }
    test("semantic zoom rejects unsafe or malformed HTML") {
        let unsafe = [
            "<script>alert(1)</script>", "<img src=\"https://example.com/a\" onerror=\"evil()\">",
            "<p style=\"color:red\">styled</p>", "<a href=\"javascript:evil()\">x</a>",
            "<a href=\"java&#x73;cript:evil()\">x</a>", "<a href=\"javascript&colon;evil()\">x</a>",
            "<img src=\"data:image/svg+xml,test\">", "<svg><a href=\"x\">x</a></svg>",
            "<iframe srcdoc=\"evil\"></iframe>", "<img srcset=\"evil\">",
            "<a href=\"java&#10;script:evil()\">x</a>", "<p onclick=x>x</p>",
            "<p><strong>x</p></strong>", "<p title=\"unterminated>x</p>",
            "<a href=\"https://example.com\" href=\"javascript:evil()\">x</a>", "<img/src=x>",
            "<p><img src=\"//example.com/a\"></p>", "<object>content</object>"
        ]
        for html in unsafe {
            check((try? SemanticZoomHTMLSanitizer.sanitize(html)) == nil, "reject \(html)")
        }
        check(try SemanticZoomHTMLSanitizer.sanitize("<p title='a > b'>safe &lt;script&gt;</p>")
              == "<p title=\"a &gt; b\">safe &lt;script&gt;</p>", "quoted delimiters and escaped text stay inert")
    }
    test("semantic zoom LRU cache identity and bounds") {
        func key(_ hash: String = "source", _ stop: Int = 50, _ provider: String = "provider", _ model: String = "model") -> SemanticZoomCache.Key {
            .init(documentHash: hash, stopPercentage: stop, providerID: provider, modelID: model)
        }
        var cache = SemanticZoomCache(capacity: 2)
        cache.insert("<p>half</p>", for: key())
        check(cache.value(for: key()) == "<p>half</p>", "unchanged source cache hit")
        check(cache.value(for: key("edited")) == nil && cache.value(for: key("source", 25)) == nil,
              "document edits and stops miss")
        check(cache.value(for: key("source", 50, "other")) == nil
              && cache.value(for: key("source", 50, "provider", "other")) == nil, "provider and model isolation")
        cache.insert("brief", for: key("source", 25))
        _ = cache.value(for: key())
        cache.insert("executive", for: key("source", 10))
        check(cache.count == 2 && cache.value(for: key("source", 25)) == nil, "least recently used entry evicted")
        check(cache.value(for: key()) != nil, "recent cache hit retained")
        cache.insert("replacement", for: key())
        check(cache.count == 2 && cache.value(for: key()) == "replacement", "overwrite does not duplicate recency")
        cache.removeAll()
        check(cache.count == 0 && cache.value(for: key()) == nil, "clear window cache")
        var disabled = SemanticZoomCache(capacity: -1)
        disabled.insert("x", for: key())
        check(disabled.count == 0, "nonpositive capacity disables cache")
    }
}
