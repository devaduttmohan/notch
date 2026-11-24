import AppKit

/// What "Copy" puts on the clipboard for a pull request, in the forms devs paste most.
enum PRCopyFormat: CaseIterable, Identifiable {
    case link, titleAndLink, branch, markdown
    var id: Self { self }

    var title: String {
        switch self {
        case .link: "Link"
        case .titleAndLink: "Title and link"
        case .branch: "Branch"
        case .markdown: "Markdown"
        }
    }
    /// For the right-click menu, where each item stands alone.
    var menuTitle: String {
        switch self {
        case .link: "Copy Link"
        case .titleAndLink: "Copy Title and Link"
        case .branch: "Copy Branch Name"
        case .markdown: "Copy as Markdown"
        }
    }
    var symbol: String {
        switch self {
        case .link: "link"
        case .titleAndLink: "text.bubble"
        case .branch: "arrow.triangle.branch"
        case .markdown: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The formats that make sense for this PR (no branch name: no Branch).
    static func available(for pr: PullRequest) -> [PRCopyFormat] {
        allCases.filter { $0 != .branch || !pr.branch.isEmpty }
    }
}

enum PRCopy {
    /// "SSE-68222: Q&A … (#5076)": the title as you'd say it in Slack.
    static func label(_ pr: PullRequest) -> String { "\(pr.title) (#\(pr.number))" }

    /// The plain text each format copies (and the menu's preview of it).
    static func text(_ format: PRCopyFormat, _ pr: PullRequest) -> String {
        switch format {
        case .link: pr.url.absoluteString
        case .titleAndLink: "\(label(pr)) \(pr.url.absoluteString)"
        case .branch: pr.branch
        case .markdown: "[#\(pr.number) \(markdownEscaped(pr.title))](\(pr.url.absoluteString))"
        }
    }

    /// A short line under each choice in the Copy menu.
    static func preview(_ format: PRCopyFormat, _ pr: PullRequest) -> String {
        switch format {
        case .link: pr.url.absoluteString.replacingOccurrences(of: "https://", with: "")
        case .titleAndLink: "Slack, Jira, Notion: pastes as a linked title"
        case .branch, .markdown: text(format, pr)
        }
    }

    /// Puts it on the clipboard. "Title and link" goes as rich text too (HTML and RTF, the
    /// title linked), so Slack, Jira, Notion and Mail paste a link with the title as its
    /// text; anywhere plain, the title and URL.
    @MainActor static func copy(_ format: PRCopyFormat, _ pr: PullRequest, to board: NSPasteboard = .general) {
        board.clearContents()
        let plain = text(format, pr)
        guard format == .titleAndLink else {
            board.setString(plain, forType: .string)
            return
        }
        let title = label(pr)
        let html = "<a href=\"\(htmlEscaped(pr.url.absoluteString))\">\(htmlEscaped(title))</a>"
        let rich = NSAttributedString(string: title, attributes: [.link: pr.url])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
        board.declareTypes(rtf == nil ? [.html, .string] : [.html, .rtf, .string], owner: nil)
        board.setString(html, forType: .html)
        if let rtf { board.setData(rtf, forType: .rtf) }
        board.setString(plain, forType: .string)
    }

    static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Square brackets in a title would end the link text early.
    static func markdownEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
