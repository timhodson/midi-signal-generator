import AppKit
import SwiftUI

/// Reports whether the hosting window can actually be seen (not minimised, not fully covered,
/// not on another Space, app not hidden), so visuals can stop drawing when nobody's looking.
struct WindowVisibility: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() })
            }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
        }

        // Observers are removed in viewDidMoveToWindow when the view leaves its window.
    }
}
