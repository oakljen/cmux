import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// a1298 and a1244, Nov 21: on a fresh install the Chief page was blank in about 5 of 8 launches (fleet captures of
/// tour:chief-onboarding-meet), and HomePendingTerminalFocusTests timed out with "Home's dock pane shows nil". Home's
/// dock pane selected its page tab and never showed it: `debug.surfaces` read `blank_reason not_shown`, no shown tab,
/// no content, while the Home page's view was made outside the pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct HomeDockShowsItsPageTests {
    /// The sampled lines and whether sampling goes on (one main-actor box the sampler and the test share).
    @MainActor final class Trace {
        var lines: [String] = []
        var on = true
    }

    /// The dock pane's state, one line (what a blank pane's report needs).
    static func line(_ window: WindowController, _ key: String?) -> String {
        let pane = key.flatMap { window.content?.paneController(key: $0) }
        let page: String
        if case .page(let view)? = pane?.currentContent {
            page = "page(\(type(of: view.content)), inPane \(view.superview != nil && view.window === window.window))"
        } else {
            page = pane?.currentContent.map { "\($0.kind)" } ?? "nil"
        }
        let chief = window.chiefPanelView.map { "panel(mounted \($0.superview != nil), holds \(($0.chief).map { "\(type(of: $0))" } ?? "-"))" } ?? "no panel"
        return "ws \(window.state.workspaceID?.suffix(4) ?? "-") content \(window.content?.workspace.id.suffix(4) ?? "-") "
            + "pane \(key?.suffix(4) ?? "-") sel \(pane?.stripModel.selectedID?.rawValue.suffix(4) ?? "-") "
            + "shown \(pane?.currentTabKey?.suffix(4) ?? "-") susp \(pane?.isSuspended ?? false) presence \(pane.map { "\($0.presence)" } ?? "-") "
            + "content \(page) \(chief)"
    }

    /// Home shows and its dock pane shows Home's page: the docked Home view, in the pane, in the window.
    @Test func homesDockPaneShowsItsPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let trace = Trace()
            // test harness: what the dock pane shows, at each change, while Home is set up and shown
            let sampler = Task { @MainActor in
                while trace.on {
                    let now = Self.line(window, window.focusedPane?.paneKey)
                    if trace.lines.last?.hasSuffix(now) != true { trace.lines.append("\(trace.lines.count): \(now)") }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { trace.on = false }
            let (_, _) = try await HomeSplitKeysTests.showHome(services, connection)
            let shell = try #require(window.window)
            defer { shell.closeWithHomePopovers() }
            let dockKey = try #require(window.focusedPane?.paneKey, "Home's dock has no focus")
            @MainActor func dockView() -> HomeDockView? {
                guard case .page(let view)? = window.content?.paneController(key: dockKey)?.currentContent,
                      view.window === shell else { return nil }
                return view.content as? HomeDockView
            }
            try await PasswordManagerRouteTests.until({ dockView() != nil }, within: .seconds(15), report: {
                "Home's dock pane shows no Home page: \(Self.line(window, dockKey))\ntrace:\n\(trace.lines.joined(separator: "\n"))"
            })
            trace.on = false
            await sampler.value
        }
    }
}
