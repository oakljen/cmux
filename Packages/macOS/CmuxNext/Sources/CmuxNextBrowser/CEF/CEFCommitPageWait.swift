import AppKit

/// One wait of a page that took its pane's next size ahead of a layout commit (``CEFTabContentView`` as a
/// `PaneCommitSurface`, on an engine with no resize fence): it reports `ready` once, when the page laid out at the
/// size (``CEFCommitLayoutWait/laidOut``, read once each display frame) or at ``readyFrames`` display frames, and asks for `release` at
/// ``releaseFrames`` frames when the page still holds that size then (a commit that never showed).
///
/// The page asks its commit to wait up to ``commitTicks`` frames for it (``PaneCommitSurface/commitWaitTicks``; the
/// commit's own bound, `ScreenContentView.commitBound`, is 3), and the commit shows the pane's ground for a surface
/// that is late. The bound here is one frame under the page's, so the page is never late: a page that has not laid out
/// by then shows its old frame at its top-left corner beside its backdrop, as before this wait.
///
/// Why longer than the commit's 3: a page frame at a new size shows about two refreshes after the page's own layout
/// (Chromium's commit, raster and draw, then the GPU's swap), so a page that lays out in 30 ms shows its frame some 5 to
/// 6 refreshes after the change at 120 Hz. At 3 the zoom of a 4x2 layout showed the page's old frame beside its
/// backdrop for up to 3 refreshes while the pane grew (films of `pane-perf --film --page-resize-work-ms=30`, cmux20-bench).
/// A page that lays out in time answers in 1 or 2 frames and its commit waits no longer than before.
final class CEFCommitPageWait {
    /// Frame ticks the page's commit may wait for it.
    static let commitTicks = 3
    /// Display frames until the page is ready whatever it answered: one under ``commitTicks``.
    static let readyFrames = commitTicks - 1
    /// Display frames until a size taken ahead for a commit that has not shown goes (the commit shows at most 4 frames
    /// after its change).
    static let releaseFrames = 8

    private var ready: (@MainActor () -> Void)?
    private var release: (@MainActor () -> Void)?
    private var stopFrames: (@MainActor () -> Void)?
    private var answer: Task<Void, Never>?
    private var frames = 0
    /// In a frame's tick: the tick's own answer stops the frames, not a call back into the frame source.
    private var inFrame = false
    private weak var tab: CEFTab?
    private let pixels: CGSize
    private let laidOut: CEFCommitLayoutWait.LaidOut
    /// A read of the page's answer is out: the next one goes at the frame after it came back.
    private var asking = false
    private var asks = 0
    private let asked = CEFTrackerStats.now()

    /// Starts the wait now: asks the page to watch for the size, then reads its answer once each display frame (one
    /// read out at a time) until it laid out there or the wait reports.
    /// - Parameters:
    ///   - tab: the page that took the size.
    ///   - view: a view in the page's window, whose display frames bound the wait.
    ///   - pixels: the page's viewport at the commit's size, in device pixels.
    ///   - wait: how the page answers and the frames come (``CEFPaneHost/commitLayoutWait``).
    ///   - ready: the commit's report; called once, never after ``cancel()``.
    ///   - release: lets the size taken ahead go; called at most once, never after ``holdEnded()`` or ``cancel()``.
    init(tab: CEFTab, view: NSView, pixels: CGSize, using wait: CEFCommitLayoutWait,
         ready: @escaping @MainActor () -> Void, release: @escaping @MainActor () -> Void) {
        self.ready = ready
        self.release = release
        self.tab = tab
        self.pixels = pixels
        laidOut = wait.laidOut
        stopFrames = wait.frames(view) { [weak self] last in self?.frame(last: last) ?? false }
        ask()
    }

    /// One read of the page's answer: the first one starts the page's watch.
    private func ask() {
        guard let tab, !asking else { return }
        asking = true
        let first = asks == 0, pixels = self.pixels, laidOut = self.laidOut
        asks += 1
        CEFHostView.trackerStats.commitAnswerReads += 1
        answer = Task { [weak self, weak tab] in
            guard let tab else { return }
            let laid = await laidOut(tab, pixels, first)
            // A later change replaced this wait (`cancel()`): its answer is void.
            guard let self, !Task.isCancelled else { return }
            self.asking = false
            guard laid else { return }
            guard self.owesReport else {
                // The wait reported at its bound before this answer came: late, not lost.
                CEFHostView.trackerStats.commitAnswersLate += 1
                return
            }
            CEFHostView.trackerStats.commitAnswerSeconds += CEFTrackerStats.now() - self.asked
            self.report(.answered)
        }
    }

    /// Whether the report is still owed.
    var owesReport: Bool { ready != nil }

    /// The page's hold of the size ended (its commit showed, or the change went): nothing is left to release, and the
    /// frames stop once the report is made.
    func holdEnded() {
        release = nil
        if ready == nil, !inFrame { stop() }
    }

    /// Why a wait reported (`debug.cef` `tracker`: `commit_answered`, `commit_at_bound`, `commit_left`).
    enum Ending {
        /// The page laid out at the size: the wait ended at once.
        case answered
        /// The page had not laid out by ``readyFrames``.
        case atBound
        /// The page hid, left its pane or its window stopped giving frames.
        case left
    }

    /// Reports now, if not yet: by default the page hides or leaves its pane (it draws nothing more for this commit).
    func report(_ ending: Ending = .left) {
        guard let ready else { return }
        self.ready = nil
        switch ending {
        case .answered: CEFHostView.trackerStats.commitWaitsAnswered += 1
        case .atBound: CEFHostView.trackerStats.commitWaitsAtBound += 1
        case .left: CEFHostView.trackerStats.commitWaitsLeft += 1
        }
        if release == nil, !inFrame { stop() }
        ready()
    }

    /// Ends the wait with no report and no release (a later change replaced it).
    func cancel() {
        ready = nil
        release = nil
        answer?.cancel()
        answer = nil
        stop()
    }

    private func frame(last: Bool) -> Bool {
        inFrame = true
        defer { inFrame = false }
        frames += 1
        if last { report(.left) } else if frames >= Self.readyFrames { report(.atBound) } else if owesReport { ask() }
        if last || frames >= Self.releaseFrames, let release {
            self.release = nil
            release()
        }
        let ticking = ready != nil || release != nil
        if !ticking { stopFrames = nil }
        return ticking
    }

    private func stop() {
        let stop = stopFrames
        stopFrames = nil
        stop?()
    }
}
