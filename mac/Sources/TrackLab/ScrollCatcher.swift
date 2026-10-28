import AppKit
import SwiftUI

/// Pega a rolagem (dois dedos no trackpad, roda do mouse) sobre a área onde fica, sem pegar cliques: um monitor local
/// de eventos confere se o ponteiro está dentro desta view. `onScroll` recebe o deslocamento em pontos (a roda do
/// mouse vira pontos) e a largura da área; devolve se a rolagem foi usada (então ela não chega a quem está por baixo).
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (_ dx: Double, _ dy: Double, _ width: Double) -> Bool

    /// Quantos pontos vale uma linha da roda do mouse.
    static let pointsPerLine = 20.0

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, Double, Double) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 1 : ScrollCatcher.pointsPerLine
                let used = self.onScroll?(Double(event.scrollingDeltaX) * scale, Double(event.scrollingDeltaY) * scale,
                                          Double(self.bounds.width)) ?? false
                return used ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
