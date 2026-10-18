import AppKit
import WebKit

/// Renders a write-up's Markdown to README.pdf next to it, through a
/// small Markdown-to-HTML pass and an offscreen WKWebView.
@MainActor
enum PDFExporter {
    static func export(folder: URL, markdown: String) async throws -> URL {
        let html = page(body: MarkdownHTML.render(markdown))
        let htmlURL = folder.appendingPathComponent(".README.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100))
        let loader = NavigationWaiter()
        web.navigationDelegate = loader
        web.loadFileURL(htmlURL, allowingReadAccessTo: folder)
        try await loader.wait()

        let data: Data = try await withCheckedThrowingContinuation { c in
            web.createPDF(configuration: WKPDFConfiguration()) { result in c.resume(with: result) }
        }
        let url = folder.appendingPathComponent("README.pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func page(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 14px -apple-system, system-ui; color: #1d1d1f; max-width: 720px; margin: 32px auto; line-height: 1.5; }
        h1 { font-size: 26px; } h2 { font-size: 18px; margin-top: 28px; }
        img { max-width: 100%; border-radius: 8px; border: 1px solid #ddd; }
        blockquote { border-left: 3px solid #5a5cf2; margin: 8px 0; padding: 2px 12px; color: #444; }
        code { font: 12px ui-monospace, Menlo; background: #f2f2f5; padding: 1px 4px; border-radius: 4px; }
        </style></head><body>\(body)</body></html>
        """
    }

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        private var failure: Error?

        func wait() async throws {
            if finished { if let failure { throw failure }; return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in continuation = c }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(error)
        }

        private func finish(_ error: Error?) {
            finished = true
            failure = error
            guard let c = continuation else { return }
            continuation = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

/// Enough Markdown for write-ups: headings, images, lists, quotes, links,
/// bold, italics and inline code.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var html: [String] = []
        var inList = false
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        func closeList() {
            if inList { html.append("</ul>"); inList = false }
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); closeList(); continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if level > 0, level <= 6, line.dropFirst(level).first == " " {
                flushParagraph(); closeList()
                html.append("<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                if !inList { html.append("<ul>"); inList = true }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph(); closeList()
        return html.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, #"<img alt="$1" src="$2">"#),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, #"<a href="$2">$1</a>"#),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"(?<![*\w])\*([^*]+)\*(?![*\w])"#, "<em>$1</em>"),
            (#"`([^`]+)`"#, "<code>$1</code>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
