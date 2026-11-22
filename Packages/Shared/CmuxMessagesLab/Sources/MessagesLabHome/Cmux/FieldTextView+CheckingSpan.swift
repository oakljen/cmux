// cmux: text checking reads the words around a range of a long paragraph, not the paragraph. Not a vendored file.
//
// AppKit's `NSTextCheckingController` (automatic correction, text replacement, quote and dash substitution,
// candidates; continuous spell checking is `DeferredSpellChecker`, off the key) asks the field for an annotated copy
// of the text around a range four or five times a key (`annotatedSubstringForProposedRange:actualRange:`, the
// public `NSTextCheckingClient` protocol). NSTextView answers with the whole paragraph and merges its
// temporary-attribute runs over all of it (`temporaryAttributesAtCharacterIndex:longestEffectiveRange:inRange:`): at
// a 3,000-character one-paragraph draft those copies were about a fifth of each key's main-thread work (cmux21
// `sample`, 300 keys; a1250, 2026-11-21). The protocol lets a client cut a paragraph that exceeds a maximum length;
// the field answers a long one with the words around the range, built as AppKit builds its copy: the characters,
// with the TextKit 1 layout manager's temporary attributes (the spelling marks and the controller's annotations).
import AppKit

/// NSTextView's own `annotatedSubstringForProposedRange:actualRange:`, for the cases the field leaves to it.
private typealias AnnotatedCopy = @convention(c) (AnyObject, Selector, NSRange, UnsafeMutablePointer<NSRange>?) -> Unmanaged<NSAttributedString>?
private let annotatedCopySelector = NSSelectorFromString("annotatedSubstringForProposedRange:actualRange:")
private let appKitAnnotatedCopy = unsafeBitCast(class_getMethodImplementation(NSTextView.self, annotatedCopySelector), to: AnnotatedCopy.self)

/// Whether UNIT ends a paragraph for `NSString.paragraphRange(for:)`: LF, CR and U+2029, CRLF as one (not NEL,
/// U+2028, form feed or vertical tab; probe on macOS 27, cmux21). UTF-16 units, not characters: a CRLF is one
/// character, and `rangeOfCharacter(from:)` mis-found it, and a separator before a range that ends inside a
/// surrogate pair.
private func isParagraphSeparator(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D || unit == 0x2029 }

/// The span of a long paragraph that text checking reads around a range.
struct FieldCheckingSpan {
    /// A paragraph longer than this (UTF-16 units) is read around the range only.
    let longParagraph: Int
    /// How far the span reaches on each side of the range, before it widens to whole words.
    let radius: Int
    /// The furthest the span widens to reach a word boundary.
    let wordSlack: Int

    /// The checks a key runs (autocorrection, text replacement, quote and dash substitution, candidates) read a
    /// few words either side of the caret: 128 units, then up to 64 more to a word boundary.
    init(longParagraph: Int = 1024, radius: Int = 128, wordSlack: Int = 64) {
        self.longParagraph = longParagraph
        self.radius = radius
        self.wordSlack = wordSlack
    }

    /// The span text checking reads for `proposed` in `text`, or nil when NSTextView's answer stands: a proposal of
    /// the whole document (`NSNotFound`), one outside the text, or one in a paragraph no longer than `longParagraph`.
    ///
    /// The paragraph's ends are looked for no further than `longParagraph` units from the range: a key reads the
    /// words around its caret, not its whole paragraph (`paragraphRange(for:)` walked all of it, four or five times
    /// a key).
    func range(proposed: NSRange, in text: NSString) -> NSRange? {
        guard proposed.location != NSNotFound, proposed.location <= text.length else { return nil }
        let clamped = NSRange(location: proposed.location, length: min(proposed.length, text.length - proposed.location))
        let reach = longParagraph + 1
        let back = max(0, clamped.location - reach)
        // A range that starts between the CR and LF of a CRLF starts in the paragraph that CRLF ends.
        var upTo = clamped.location
        if upTo > 0, upTo < text.length, text.character(at: upTo - 1) == 0x0D, text.character(at: upTo) == 0x0A { upTo -= 1 }
        // The paragraph's start: after the last separator before the range, or nil when it is further than REACH.
        var start: Int? = back == 0 ? 0 : nil
        if let i = lastSeparator(in: text, NSRange(location: back, length: max(0, upTo - back))) { start = i + 1 }
        // Its end: after the range's own last character when that ends the paragraph, else after the first
        // separator from the range's end (CRLF whole), or nil past REACH.
        let from = NSMaxRange(clamped), ahead = min(text.length, from + reach)
        var end: Int? = ahead == text.length ? text.length : nil
        var stop: Int?
        if clamped.length > 0, isParagraphSeparator(text.character(at: from - 1)) { stop = from - 1 }
        else { stop = firstSeparator(in: text, NSRange(location: from, length: ahead - from)) }
        if let stop {
            let crlf = text.character(at: stop) == 0x0D && stop + 1 < text.length && text.character(at: stop + 1) == 0x0A
            end = stop + 1 + (crlf ? 1 : 0)
        }
        if let start, let end, end - start <= longParagraph { return nil }
        let lowest = start ?? 0, highest = end ?? text.length
        let lo = max(lowest, clamped.location - radius)
        let hi = min(highest, NSMaxRange(clamped) + radius)
        let first = widen(lo, by: -1, in: text, limit: lowest)
        let last = widen(hi, by: 1, in: text, limit: highest)
        return NSRange(location: first, length: last - first)
    }

    /// The index of the last paragraph separator in RANGE of TEXT, or nil (its units read once, on the stack).
    private func lastSeparator(in text: NSString, _ range: NSRange) -> Int? {
        guard range.length > 0 else { return nil }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: range.length) { units in
            text.getCharacters(units.baseAddress!, range: range)
            return units.lastIndex(where: isParagraphSeparator).map { range.location + $0 }
        }
    }

    /// The index of the first paragraph separator in RANGE of TEXT, or nil.
    private func firstSeparator(in text: NSString, _ range: NSRange) -> Int? {
        guard range.length > 0 else { return nil }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: range.length) { units in
            text.getCharacters(units.baseAddress!, range: range)
            return units.firstIndex(where: isParagraphSeparator).map { range.location + $0 }
        }
    }

    /// `index` moved in `step` direction to the nearest white space, at most `wordSlack` units and never past `limit`.
    private func widen(_ index: Int, by step: Int, in text: NSString, limit: Int) -> Int {
        var i = index
        for _ in 0..<wordSlack {
            if i == limit { return i }
            let unit = step < 0 ? text.character(at: i - 1) : text.character(at: i)
            if let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { return i }
            i += step
        }
        return i
    }
}

extension FieldTextView {
    /// Text checking's annotated copy (``FieldCheckingSpan``): a long paragraph's span around `range`, else
    /// NSTextView's answer.
    @objc(annotatedSubstringForProposedRange:actualRange:)
    func checkingCopy(forProposedRange range: NSRange, actualRange: UnsafeMutablePointer<NSRange>?) -> NSAttributedString? {
        let text = string as NSString
        guard textLayoutManager == nil, let layout = layoutManager,
              let span = FieldCheckingSpan().range(proposed: range, in: text) else {
            return appKitAnnotatedCopy(self, annotatedCopySelector, range, actualRange)?.takeUnretainedValue()
        }
        let copy = NSMutableAttributedString(string: text.substring(with: span))
        var at = span.location
        while at < NSMaxRange(span) {
            var run = NSRange(location: NSNotFound, length: 0)
            let attributes = layout.temporaryAttributes(atCharacterIndex: at, longestEffectiveRange: &run, in: span)
            guard run.length > 0 else { break }
            if !attributes.isEmpty { copy.addAttributes(attributes, range: NSRange(location: run.location - span.location, length: run.length)) }
            at = NSMaxRange(run)
        }
        actualRange?.pointee = span
        return copy
    }
}
