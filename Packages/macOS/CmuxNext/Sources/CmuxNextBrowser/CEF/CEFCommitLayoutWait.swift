import AppKit
import CmuxNextWakeups

/// How a Chromium page that took its pane's next size ahead of a layout commit (a zoom, the close of a pane beside it)
/// tells that it laid out at that size, on an engine with no resize fence (fork API 33 and older): the page's own
/// animation frames, watched by a script, read once each display frame of its window, which also bound the wait.
/// Chromium shows its GPU output through a `CALayerHost` of the GPU process's context
/// (`DisplayCALayerTree::GotCALayerFrame`), so no layer in this process carries the size of the frame it shows.
///
/// The renderer's script path (fork API 29) answers with a script's value at once and does not wait for a promise, so
/// the watch is started by one script and read by others, each of which returns at once (an `async` script there
/// answers with its promise, never its value: every wait then ran to its bound, pane-perf on cmux20-bench, 2026-11-22).
///
/// A seam of ``CEFPaneHost``: tests pass their own answers and frames.
struct CEFCommitLayoutWait {
    /// Answers true once `tab`'s page laid out at `pixels` (its viewport in device pixels) and began the frame after
    /// that one, so the frame at the new size went to the GPU; false while it has not or when it cannot tell. `first`:
    /// this read starts the page's watch for that size.
    typealias LaidOut = @MainActor (_ tab: CEFTab, _ pixels: CGSize, _ first: Bool) async -> Bool
    /// Calls `tick(false)` once per display frame of `view`'s window until it returns false, or `tick(true)` once when
    /// no frame comes any more (the window closed or went out of sight). Returns the block that stops the ticks.
    typealias Frames = @MainActor (_ view: NSView, _ tick: @escaping @MainActor (_ last: Bool) -> Bool) -> @MainActor () -> Void

    let laidOut: LaidOut
    let frames: Frames

    /// - Parameters:
    ///   - laidOut: the page's answer; by default scripts in the page's isolated world (``pageLaidOut(_:_:_:)``).
    ///   - frames: the display frames; by default those of the view's window (``windowFrames(_:_:)``).
    init(laidOut: @escaping LaidOut = CEFCommitLayoutWait.pageLaidOut, frames: @escaping Frames = CEFCommitLayoutWait.windowFrames) {
        self.laidOut = laidOut
        self.frames = frames
    }

    /// Runs ``watchScript(_:)`` (`first`) or ``readScript(_:)`` in the page's isolated world. Only on the renderer path
    /// (fork API 29): a DevTools evaluation would open a session (and keep the page's renderer from being shared) for a
    /// wait the display frames bound anyway.
    static func pageLaidOut(_ tab: CEFTab, _ pixels: CGSize, _ first: Bool) async -> Bool {
        guard tab.runtime.forkFeatures.rendererPaths else { return false }
        do {
            let script = first ? watchScript(pixels) : readScript(pixels)
            return try await tab.evaluate(script, world: .isolated, gesture: .cmux) == .bool(true)
        } catch {
            CEFHostView.trackerStats.commitAnswersFailed += 1
            return false
        }
    }

    /// Starts the page's watch for `pixels` and answers at once whether it already saw it: at each animation frame,
    /// whether the viewport is `pixels` in device pixels (page zoom aside: `innerWidth` is in CSS pixels); once it is,
    /// the watch waits one frame more, so the frame laid out at that size went to the compositor, and then it is done.
    /// It gives up after 30 frames at another size. A newer watch replaces it.
    nonisolated static func watchScript(_ pixels: CGSize) -> String {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        return """
        (() => {
          const watch = { w: \(width), h: \(height), done: false };
          globalThis.__cmuxCommitLayout = watch;
          const at = () => Math.abs(innerWidth * devicePixelRatio - watch.w) <= devicePixelRatio + 1
            && Math.abs(innerHeight * devicePixelRatio - watch.h) <= devicePixelRatio + 1;
          let left = 30;
          const step = () => {
            if (globalThis.__cmuxCommitLayout !== watch) return;
            if (at()) { requestAnimationFrame(() => { watch.done = true; }); return; }
            if (--left > 0) requestAnimationFrame(step);
          };
          requestAnimationFrame(step);
          return false;
        })()
        """
    }

    /// Whether the page's watch for `pixels` is done (``watchScript(_:)``); answers at once.
    nonisolated static func readScript(_ pixels: CGSize) -> String {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        return """
        (() => {
          const watch = globalThis.__cmuxCommitLayout;
          return !!watch && watch.w === \(width) && watch.h === \(height) && watch.done === true;
        })()
        """
    }

    /// The display frames of `view`'s window, through a ``FrameClient`` that is no animation.
    static func windowFrames(_ view: NSView, _ tick: @escaping @MainActor (_ last: Bool) -> Bool) -> @MainActor () -> Void {
        let client = FrameClient(owner: "cef.commit-layout", isAnimation: false,
                                 scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app },
                                 settle: { _ = tick(true) }, dropped: { _ = tick(true) }) { _ in tick(false) }
        client.activate()
        return { client.deactivate() }
    }
}
