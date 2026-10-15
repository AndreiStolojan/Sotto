import MarkdownUI
import SwiftUI

/// Renders transcripts and assistant responses as Markdown. Images are never loaded: an image link in
/// spoken or generated text (`![](https://host/pixel)`) would otherwise make a network request on display.
/// Every Markdown view in the app goes through here; `scripts/test-core.sh` checks that.
struct MarkdownContentView: View {
    let text: String
    var fontSize: CGFloat
    var foregroundColor: Color
    var alignment: Alignment

    init(
        _ text: String,
        fontSize: CGFloat,
        foregroundColor: Color,
        alignment: Alignment = .leading
    ) {
        self.text = text
        self.fontSize = fontSize
        self.foregroundColor = foregroundColor
        self.alignment = alignment
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(fontSize)
                ForegroundColor(foregroundColor)
            }
            .markdownImageProvider(NoImageProvider())
            .markdownInlineImageProvider(NoInlineImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// Block images render as nothing.
private struct NoImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

/// Inline images always fail to load, so MarkdownUI leaves them out.
private struct NoInlineImageProvider: InlineImageProvider {
    struct Disabled: Error {}

    func image(with url: URL, label: String) async throws -> Image {
        throw Disabled()
    }
}
