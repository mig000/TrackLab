import AppKit
import SwiftUI

/// O relógio do transporte ("0:35 / 6:06 · compasso 25") fora do layout do SwiftUI: uma NSView que se desenha sozinha
/// cinco vezes por segundo e só pede para ser redesenhada quando o texto muda. Um Text que muda a cada segundo fazia o
/// AppKit refazer as restrições da janela inteira (~40 ms, dois quadros perdidos por segundo na Fita), mesmo com a
/// moldura de tamanho fixo.
struct ClockLabel: NSViewRepresentable {
    let text: () -> String

    func makeNSView(context: Context) -> LabelView {
        let view = LabelView()
        view.text = text
        return view
    }

    func updateNSView(_ view: LabelView, context: Context) {
        view.text = text
        view.refresh()
    }

    static func dismantleNSView(_ view: LabelView, coordinator: ()) {
        view.stop()
    }

    final class LabelView: NSView {
        var text: (() -> String)?
        private var shown = ""
        private var timer: Timer?

        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func refresh() {
            let value = text?() ?? ""
            guard value != shown else { return }
            shown = value
            setAccessibilityValue(value)
            needsDisplay = true
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

        override func draw(_ dirtyRect: NSRect) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let string = NSAttributedString(string: shown, attributes: attributes)
            let y = (bounds.height - string.size().height) / 2
            string.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: string.size().height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
