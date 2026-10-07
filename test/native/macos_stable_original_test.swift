import AppKit

@main
struct StableOriginalTests {
    static func main() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let view = TranscriptView()
                let original = "Hi 👋 世界 again"
                func render(_ stable: String, final: Bool = false) {
                    view.update([["original": original, "stableOriginal": stable, "final": final]])
                }
                func color(_ offset: Int) -> NSColor {
                    let range = (view.text.string as NSString).range(of: original)
                    precondition(range.location != NSNotFound)
                    return view.text.textStorage!.attribute(.foregroundColor, at: range.location + offset, effectiveRange: nil) as! NSColor
                }
                render("")
                precondition(color(0).isEqual(NSColor.secondaryLabelColor))
                render("Hi 👋 世界")
                precondition(color(0).isEqual(NSColor.labelColor))
                precondition(color("Hi 👋 世界".utf16.count).isEqual(NSColor.secondaryLabelColor))
                precondition(view.text.string.contains("识别中 · 可修订"))
                precondition(!view.text.string.contains("已确认"))
                render("Different source")
                precondition(color(0).isEqual(NSColor.secondaryLabelColor))
                render("Hi", final: true)
                precondition(color(0).isEqual(NSColor.labelColor))
                precondition(color(original.utf16.count - 1).isEqual(NSColor.labelColor))
                precondition(view.text.string.contains("已确认"))
            }
        }
        print("Native stable-source rendering: light/dark, Unicode prefix, empty/mismatched prefix, final status passed")
    }
}
