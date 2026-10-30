// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)

import SwiftUI

/// A small Markdown reader for agent answers: headings, bullets, fenced code
/// and inline emphasis. Links and code stay selectable; nothing is executed.
public struct MarkdownText: View {
    private let blocks: [Block]

    public init(_ text: String) {
        blocks = Block.parse(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case let .paragraph(value):
                    inline(value)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                case let .heading(value):
                    inline(value)
                        .font(.headline)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                case let .bullets(items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•").foregroundStyle(.secondary)
                                inline(item)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                case let .code(language, value):
                    VStack(alignment: .leading, spacing: 4) {
                        if !language.isEmpty {
                            Text(language)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(value)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ value: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(value)
    }

    struct Block: Identifiable {
        enum Kind {
            case paragraph(String)
            case heading(String)
            case bullets([String])
            case code(String, String)
        }

        let id = UUID()
        let kind: Kind

        private static let fence = try! NSRegularExpression(pattern: #"^\s*```(\S*)\s*$"#)
        private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
        private static let bullet = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+(.*)$"#)
        private static let ordered = try! NSRegularExpression(pattern: #"^\s*\d+[.)]\s+(.*)$"#)

        static func parse(_ source: String) -> [Block] {
            var blocks: [Block] = []
            let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            var index = 0

            func capture(_ regex: NSRegularExpression, _ line: String) -> [String]? {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range) else { return nil }
                return (1..<match.numberOfRanges).map { number in
                    guard let r = Range(match.range(at: number), in: line) else { return "" }
                    return String(line[r])
                }
            }

            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                }

                if let groups = capture(fence, line) {
                    let language = groups.first ?? ""
                    var body: [String] = []
                    index += 1
                    while index < lines.count, capture(fence, lines[index]) == nil {
                        body.append(lines[index])
                        index += 1
                    }
                    index += 1
                    blocks.append(Block(kind: .code(language, body.joined(separator: "\n"))))
                    continue
                }

                if let groups = capture(heading, line) {
                    blocks.append(Block(kind: .heading(groups.last ?? "")))
                    index += 1
                    continue
                }

                if capture(bullet, line) != nil || capture(ordered, line) != nil {
                    var items: [String] = []
                    while index < lines.count {
                        let current = lines[index]
                        if let groups = capture(bullet, current) ?? capture(ordered, current) {
                            items.append(groups.last ?? "")
                            index += 1
                        } else {
                            break
                        }
                    }
                    blocks.append(Block(kind: .bullets(items)))
                    continue
                }

                var body: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if capture(fence, current) != nil || capture(heading, current) != nil
                        || capture(bullet, current) != nil || capture(ordered, current) != nil {
                        break
                    }
                    body.append(current)
                    index += 1
                }
                blocks.append(Block(kind: .paragraph(body.joined(separator: "\n"))))
            }
            return blocks
        }
    }
}
#endif
