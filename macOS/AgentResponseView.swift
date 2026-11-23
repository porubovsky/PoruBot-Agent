import SwiftUI
import AppKit

enum ResponseBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case item(String, Int, String)
    case code(String)
    case separator

    static func parse(_ response: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        var code: [String]?
        let lines = response.components(separatedBy: .newlines)
        let escaped = lines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\\#") ||
            $0.range(of: #"^\s*(?:\\[*+-]|\d+\\\.)\s"#, options: .regularExpression) != nil
        }
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for original in lines {
            let line = escaped && code == nil
                ? original.replacingOccurrences(of: #"\\([#*_`\[\]().+!-])"#, with: "$1", options: .regularExpression)
                : original
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") {
                flush()
                if let content = code { blocks.append(.code(content.joined(separator: "\n"))); code = nil }
                else { code = [] }
            } else if code != nil {
                code?.append(original)
            } else if clean.isEmpty {
                flush()
            } else if let heading = clean.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flush()
                blocks.append(.heading(heading.1.count, String(heading.2)))
            } else if let item = clean.wholeMatch(of: /([-*+]|[0-9]{1,9}[.)])\s+(.+)/) {
                flush()
                let marker = String(item.1)
                blocks.append(.item(marker.count == 1 ? "•" : marker,
                                    min(3, max(0, (line.count - line.drop(while: \.isWhitespace).count) / 2)),
                                    String(item.2)))
            } else if ["---", "***", "___"].contains(clean) {
                flush()
                blocks.append(.separator)
            } else {
                paragraph.append(clean)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}

struct AgentResponseView: View {
    let response: String

    var body: some View {
        let blocks = ResponseBlock.parse(response)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case let .heading(level, title):
                    inline(title).font(.system(size: level <= 2 ? 20 : 16, weight: .semibold))
                        .padding(.top, index == 0 ? 0 : 6).accessibilityAddTraits(.isHeader)
                case let .paragraph(text):
                    inline(text)
                case let .item(marker, depth, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).fontWeight(.medium).foregroundStyle(.secondary)
                        inline(text)
                    }.padding(.leading, CGFloat(depth) * 14)
                case let .code(text):
                    ScrollView(.horizontal) {
                        Text(verbatim: text).font(.system(.body, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false).padding(10)
                    }.background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                case .separator:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .font(.system(size: 14)).lineSpacing(4)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if url.isFileURL {
                guard url.host == nil || url.host == "" || url.host == "localhost",
                      FileManager.default.fileExists(atPath: url.path) else { return .discarded }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .handled
            }
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                ? .systemAction : .discarded
        })
    }

    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)).map(Text.init)
            ?? Text(verbatim: source)
    }
}
