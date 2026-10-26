import AppKit

/// HTML and RTF versions of a dictation that contains a list, so apps with real lists (Notes, Mail,
/// Google Docs, Notion) get one instead of typed "1." lines. Browsers read the HTML, Cocoa apps the RTF,
/// and plain-text fields keep using the plain string.
enum RichText {
    private enum Line {
        case text(String)
        case item(ordered: Bool, number: Int, text: String)
    }

    /// Nil when the text has fewer than two list lines; plain text is all it needs then.
    static func flavors(for text: String) -> (html: String, rtf: Data)? {
        let lines = parse(text)
        guard lines.filter({ if case .item = $0 { return true } else { return false } }).count >= 2 else { return nil }
        guard let rtf = rtf(lines) else { return nil }
        return (html(lines), rtf)
    }

    private static func parse(_ text: String) -> [Line] {
        text.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.+)$/#) {
                return .item(ordered: true, number: Int(m.1) ?? 1, text: String(m.2))
            }
            if let m = line.firstMatch(of: #/^[-•*]\s+(.+)$/#) {
                return .item(ordered: false, number: 0, text: String(m.1))
            }
            return .text(raw)
        }
    }

    private static func html(_ lines: [Line]) -> String {
        var out = "<meta charset=\"utf-8\">"
        var open: Bool? = nil  // the kind of list currently open, if any
        for line in lines {
            switch line {
            case let .item(ordered, number, text):
                if open != ordered {
                    if let o = open { out += o ? "</ol>" : "</ul>" }
                    out += ordered ? (number == 1 ? "<ol>" : "<ol start=\"\(number)\">") : "<ul>"
                    open = ordered
                }
                out += "<li>\(escape(text))</li>"
            case let .text(text):
                if let o = open { out += o ? "</ol>" : "</ul>"; open = nil }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out += "<p>\(escape(trimmed))</p>" }
            }
        }
        if let o = open { out += o ? "</ol>" : "</ul>" }
        return out
    }

    /// Lists are written the way TextEdit stores them: the marker is part of the text, between tabs,
    /// and the paragraph carries the NSTextList.
    private static func rtf(_ lines: [Line]) -> Data? {
        let doc = NSMutableAttributedString()
        var list: NSTextList?
        var ordered = false
        for (i, line) in lines.enumerated() {
            let end = i == lines.count - 1 ? "" : "\n"
            switch line {
            case let .item(isOrdered, number, text):
                if list == nil || ordered != isOrdered {
                    list = NSTextList(markerFormat: isOrdered ? NSTextList.MarkerFormat("{decimal}.") : .disc, options: 0)
                    if isOrdered { list!.startingItemNumber = number }
                    ordered = isOrdered
                }
                let style = NSMutableParagraphStyle()
                style.textLists = [list!]
                style.tabStops = [NSTextTab(textAlignment: .left, location: 11), NSTextTab(textAlignment: .left, location: 36)]
                style.headIndent = 36
                let marker = list!.marker(forItemNumber: isOrdered ? number : 1)
                doc.append(NSAttributedString(string: "\t\(marker)\t\(text)\(end)", attributes: [.paragraphStyle: style]))
            case let .text(text):
                list = nil
                doc.append(NSAttributedString(string: text + end))
            }
        }
        return try? doc.data(from: NSRange(location: 0, length: doc.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
