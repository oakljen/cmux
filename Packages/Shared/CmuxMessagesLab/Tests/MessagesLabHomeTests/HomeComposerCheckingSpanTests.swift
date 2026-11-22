import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// AppKit's text checking (automatic correction, text replacement, quote and dash substitution, candidates) asks the
/// field for an annotated copy of the text around a range (`annotatedSubstringForProposedRange:actualRange:`,
/// `NSTextCheckingClient`) four or five times a key. NSTextView answers with the whole paragraph and merges its
/// temporary-attribute runs over all of it: at a 3,000-character one-paragraph draft those copies were about a fifth
/// of each key's main-thread work (cmux21 `sample`, 300 keys; a1250, 2026-11-21). The protocol lets a client cut a
/// long paragraph short; the field answers a long one with the words around the range, with the same annotations
/// AppKit's copy has there. The real Home view over the mock owner, in an offscreen window; the calls go through the
/// Objective-C selector, as the checking controller sends them.
@MainActor @Suite(.serialized) struct HomeComposerCheckingSpanTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    typealias Annotated = @convention(c) (AnyObject, Selector, NSRange, UnsafeMutablePointer<NSRange>?) -> Unmanaged<NSAttributedString>?
    typealias Annotate = @convention(c) (AnyObject, Selector, NSDictionary, NSRange) -> Void
    static let conversation = ConversationID("conv_chief")
    static let annotated = NSSelectorFromString("annotatedSubstringForProposedRange:actualRange:")
    static let addAnnotations = NSSelectorFromString("addAnnotations:range:")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var field: FieldTextView { view.controller.demo!.compose.textView.view }
        func close() { view.stop(); window.close(); store.stop() }

        /// What text checking gets for PROPOSED: through the field's own method (as the controller sends it), or
        /// through NSTextView's (AppKit's answer).
        func copy(_ proposed: NSRange, appKit: Bool = false) -> (text: NSAttributedString?, actual: NSRange) {
            let imp = class_getMethodImplementation(appKit ? NSTextView.self : object_getClass(field), HomeComposerCheckingSpanTests.annotated)
            let call = unsafeBitCast(imp, to: Annotated.self)
            var actual = NSRange(location: NSNotFound, length: 0)
            let text = call(field, HomeComposerCheckingSpanTests.annotated, proposed, &actual)?.takeUnretainedValue()
            return (text, actual)
        }
    }

    private func rig(draft: String) async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 12, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()
        let r = Rig(store: store, window: window, view: view)
        window.makeFirstResponder(r.field)
        r.field.insertText(draft, replacementRange: r.field.selectedRange())
        try #require(r.field.textLayoutManager == nil, "the field is TextKit 1 (its annotations are the layout manager's temporary attributes)")
        return r
    }

    /// A one-paragraph draft of about 3,000 characters, a misspelling every 26.
    private static let long = String(repeating: "the chief reads yuor note ", count: 116)

    /// The caret in a long paragraph: text checking reads the words around it, not the paragraph.
    @Test func aLongParagraphIsReadAroundTheRange() async throws {
        let r = try await rig(draft: Self.long)
        defer { r.close() }
        let length = (r.field.string as NSString).length
        let caret = NSRange(location: 1500, length: 0)
        let ours = r.copy(caret)
        let text = try #require(ours.text)
        #expect(ours.actual.length < 800, "text checking read \(ours.actual.length) of the paragraph's \(length) characters")
        #expect(NSLocationInRange(caret.location, ours.actual), "the span \(ours.actual) leaves out the caret")
        #expect(text.length == ours.actual.length)
        #expect(text.string == (r.field.string as NSString).substring(with: ours.actual))
    }

    /// The span carries what AppKit's copy has over the same characters: the spelling marks and the checking
    /// controller's own annotations.
    @Test func theSpanHasAppKitsAnnotations() async throws {
        let r = try await rig(draft: Self.long)
        defer { r.close() }
        let field = r.field
        field.setSpellingState(0, range: NSRange(location: 0, length: (field.string as NSString).length))
        for at in stride(from: 16, to: 3000, by: 26) {
            field.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: NSRange(location: at, length: 4))
        }
        let annotate = unsafeBitCast(class_getMethodImplementation(NSTextView.self, Self.addAnnotations), to: Annotate.self)
        annotate(field, Self.addAnnotations, ["NSTextChecked": "1"] as NSDictionary, NSRange(location: 1200, length: 600))
        annotate(field, Self.addAnnotations, ["NSTextAlternatives": "x"] as NSDictionary, NSRange(location: 1490, length: 5))
        for proposed in [NSRange(location: 1500, length: 0), NSRange(location: 1488, length: 30), NSRange(location: 4, length: 0)] {
            let ours = r.copy(proposed)
            let appKit = r.copy(proposed, appKit: true)
            let text = try #require(ours.text), whole = try #require(appKit.text)
            let same = whole.attributedSubstring(from: NSRange(location: ours.actual.location - appKit.actual.location, length: ours.actual.length))
            #expect(text.isEqual(to: same), "the span \(ours.actual) of \(proposed) differs from AppKit's copy there")
        }
    }

    /// The span as it was first written: the whole paragraph from `paragraphRange(for:)`, then the words around
    /// the range. The bounded scan must give the same answer.
    private static func reference(_ span: FieldCheckingSpan, proposed: NSRange, in text: NSString) -> NSRange? {
        guard proposed.location != NSNotFound, proposed.location <= text.length else { return nil }
        let clamped = NSRange(location: proposed.location, length: min(proposed.length, text.length - proposed.location))
        let paragraph = text.paragraphRange(for: clamped)
        guard paragraph.length > span.longParagraph else { return nil }
        func widen(_ index: Int, by step: Int, limit: Int) -> Int {
            var i = index
            for _ in 0..<span.wordSlack {
                if i == limit { return i }
                let unit = step < 0 ? text.character(at: i - 1) : text.character(at: i)
                if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { return i }
                i += step
            }
            return i
        }
        let lo = max(paragraph.location, clamped.location - span.radius)
        let hi = min(NSMaxRange(paragraph), NSMaxRange(clamped) + span.radius)
        let start = widen(lo, by: -1, limit: paragraph.location), end = widen(hi, by: 1, limit: NSMaxRange(paragraph))
        return NSRange(location: start, length: end - start)
    }

    /// The span is the one the whole-paragraph rule gives, for carets and selections anywhere in drafts of long and
    /// short paragraphs with LF, CR, CRLF, NEL and U+2029 breaks, at the edges of each paragraph too.
    @Test func theSpanIsTheWholeParagraphRulesAnswer() {
        let span = FieldCheckingSpan(longParagraph: 64, radius: 16, wordSlack: 8)
        var generator = SystemRandomNumberGenerator()
        let breaks = ["\n", "\r", "\r\n", "\u{85}", "\u{2029}", "\u{2028}"]
        let words = ["a", "chief", "reads", "yuor", "note,", "supercalifragilistic", "\u{1F600}", "\u{0645}\u{0631}"]
        var differ: [String] = []
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                for _ in 0..<Int.random(in: 0...40, using: &generator) { text += words.randomElement(using: &generator)! + " " }
                text += breaks.randomElement(using: &generator)!
            }
            let ns = text as NSString
            for location in Set([0, ns.length] + (0..<12).map { _ in Int.random(in: 0...ns.length, using: &generator) }) {
                for length in [0, 1, 3, 30] where location + length <= ns.length {
                    let proposed = NSRange(location: location, length: length)
                    let got = span.range(proposed: proposed, in: ns), want = Self.reference(span, proposed: proposed, in: ns)
                    if got != want { differ.append("\(proposed) in \(ns.length): \(String(describing: got)) want \(String(describing: want))") }
                }
            }
        }
        #expect(differ.isEmpty, "\(differ.count) spans differ from the whole-paragraph rule: \(differ.prefix(3))")
    }

    /// A key's span costs the words around the caret, not the paragraph: the same median time at the end of a
    /// 3,000 and a 300,000 character paragraph (the whole-paragraph rule walked all of it, four or five times a key).
    @Test func theSpanDoesNotReadTheWholeParagraph() {
        let span = FieldCheckingSpan()
        func median(_ text: NSString) -> Duration {
            let clock = ContinuousClock(), caret = NSRange(location: text.length - 10, length: 0)
            var times: [Duration] = []
            for _ in 0..<101 {
                let start = clock.now
                _ = span.range(proposed: caret, in: text)
                times.append(clock.now - start)
            }
            return times.sorted()[50]
        }
        let short = median(String(repeating: "the chief reads your note ", count: 116) as NSString)
        let long = median(String(repeating: "the chief reads your note ", count: 11_600) as NSString)
        #expect(long < max(short * 3, .microseconds(20)), "a span at the end of a 300,000 character paragraph takes \(long), of a 3,000 character one \(short)")
    }

    /// A short paragraph is AppKit's own answer, whole.
    @Test func aShortParagraphIsAppKitsAnswer() async throws {
        let r = try await rig(draft: "short line\n" + Self.long + "\nlast")
        defer { r.close() }
        for proposed in [NSRange(location: 2, length: 0), NSRange(location: (r.field.string as NSString).length - 1, length: 0)] {
            let ours = r.copy(proposed), appKit = r.copy(proposed, appKit: true)
            #expect(ours.actual == appKit.actual)
            #expect(ours.text?.isEqual(to: appKit.text) == true)
        }
    }
}
