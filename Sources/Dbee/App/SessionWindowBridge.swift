import AppKit
import SwiftUI

/// Connects a session window's SwiftUI content to its NSWindow:
/// - gives the session its window, so prompts such as the SSH host key check are sheets on it;
/// - sizes the window by phase: a compact window for the connection form, the workspace size once
///   connected (the last workspace frame of this window, or 1200×760 the first time).
///
/// Use as `.background(SessionWindowBridge(session: session, showsWorkspace: session.config != nil))`.
struct SessionWindowBridge: NSViewRepresentable {
    let session: DatabaseSession
    var showsWorkspace: Bool

    static let connectSize = NSSize(width: 760, height: 640)
    static let workspaceSize = NSSize(width: 1200, height: 760)

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.session = session
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.session = session
        view.setShowsWorkspace(showsWorkspace)
    }

    final class BridgeView: NSView {
        weak var session: DatabaseSession? {
            didSet { if let window { session?.window = window } }
        }
        private var showsWorkspace: Bool?
        /// The window's workspace frame, remembered while the connection form is shown. Memory only.
        private var workspaceFrame: NSRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            session?.window = window
            applySize(animated: false)
        }

        func setShowsWorkspace(_ value: Bool) {
            guard value != showsWorkspace else { return }
            let isChange = showsWorkspace != nil
            showsWorkspace = value
            applySize(animated: isChange)
        }

        private func applySize(animated: Bool) {
            guard let window, let showsWorkspace else { return }
            // Full screen, zoomed and tabbed windows keep their frame (tabs share one frame).
            if window.styleMask.contains(.fullScreen) || window.isZoomed || (window.tabbedWindows?.count ?? 0) > 1 { return }
            let contentSize = window.contentRect(forFrameRect: window.frame).size
            if showsWorkspace {
                let frame = workspaceFrame ?? centered(window, contentSize: NSSize(
                    width: max(contentSize.width, SessionWindowBridge.workspaceSize.width),
                    height: max(contentSize.height, SessionWindowBridge.workspaceSize.height)))
                workspaceFrame = nil
                setFrame(frame, of: window, animated: animated)
            } else {
                // The connection form always gets the same size: a smaller window (e.g. one restored from an
                // older version) clips the Connect bar at the bottom.
                let target = NSSize(width: max(SessionWindowBridge.connectSize.width, window.contentMinSize.width),
                                    height: max(SessionWindowBridge.connectSize.height, window.contentMinSize.height))
                guard contentSize != target else { return }
                if contentSize.width > target.width || contentSize.height > target.height { workspaceFrame = window.frame }
                setFrame(centered(window, contentSize: target), of: window, animated: animated)
            }
        }

        /// A frame with the given content size, centered on the window's current frame.
        private func centered(_ window: NSWindow, contentSize: NSSize) -> NSRect {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
            return frame
        }

        /// Deferred to the next run loop turn: resizing the window in the middle of a SwiftUI update leaves the
        /// hosting view at the old size, clipping the bottom of the content.
        private func setFrame(_ frame: NSRect, of window: NSWindow, animated: Bool) {
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                let constrained = window.constrainFrameRect(frame, to: window.screen ?? NSScreen.main)
                window.setFrame(constrained, display: true, animate: animated && window.isVisible)
            }
        }
    }
}
