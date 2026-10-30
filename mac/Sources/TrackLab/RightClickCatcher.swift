import AppKit
import SwiftUI

/// O botão direito sobre uma view do SwiftUI, sem pegar os outros cliques: um monitor local de `rightMouseDown` (como
/// o `ScrollCatcher`), que entrega o ponto em coordenadas da view (o y de cima para baixo, como no SwiftUI).
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                return MainActor.assumeIsolated { self.onRightClick?(point) ?? false } ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
