import SwiftUI

/// Help screen, presented as a sheet from the machine list. Reads
/// `Help.md` from the app bundle and renders it with minimal block-level
/// styling (titles, headings, bullets, paragraphs) while letting
/// `AttributedString(markdown:)` handle inline formatting — bold,
/// italic, links.
///
/// We intentionally don't use a full-featured Markdown renderer: the help
/// text is authored in-repo so we control the subset of syntax used, and
/// a ~50-line parser keeps the dependency surface zero.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [Block] = []

    enum Block {
        case title(String)
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        render(block)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            blocks = Self.loadBlocks()
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .title(let text):
            Text(text)
                .font(.largeTitle.weight(.bold))
                .padding(.top, 4)
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Self.markdownText(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Self.markdownText(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func markdownText(_ text: String) -> Text {
        if let attr = try? AttributedString(markdown: text) {
            return Text(attr)
        }
        return Text(text)
    }

    // MARK: - Loader + parser

    private static func loadBlocks() -> [Block] {
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(raw)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}
