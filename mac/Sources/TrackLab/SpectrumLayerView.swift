import AppKit
import QuartzCore
import SwiftUI
import TrackLabCore

/// O espectro da Fita na GPU: a imagem (um pixel por quadro, `SpectrumPalette.rowScale` por linha) cortada em ladrilhos
/// de `tileFrames` quadros (abaixo do limite de textura da placa), cada um uma CALayer enviada à placa uma vez. A cada
/// quadro só muda a transformação do contêiner (onde a janela de tempo e a de alturas caem na tela) e o Core Animation
/// compõe na GPU, com interpolação bilinear. Antes, o Canvas redesenhava a imagem esticada na CPU a cada quadro e a
/// rolagem engasgava no iMac.
struct SpectrumLayerView: NSViewRepresentable {
    let image: CGImage?
    /// O começo da janela (segundos), quantos segundos ela mostra e a faixa de alturas.
    let start: Double
    let span: Double
    let pitches: ClosedRange<Double>
    let spectrum: Spectrum?

    func makeNSView(context: Context) -> HostView { HostView() }

    func updateNSView(_ view: HostView, context: Context) {
        view.show(image: image, spectrum: spectrum, start: start, span: span, pitches: pitches)
    }

    final class HostView: NSView {
        static let tileFrames = 4096
        private let container = CALayer()
        private weak var shown: CGImage?
        private var placed: (start: Double, span: Double, pitches: ClosedRange<Double>, size: CGSize)?
        private var last: (spectrum: Spectrum?, start: Double, span: Double, pitches: ClosedRange<Double>)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Uma view que hospeda a camada (a camada antes de `wantsLayer`): o AppKit não mexe nas subcamadas. A
            // geometria fica a do AppKit, com o y para cima: um `isGeometryFlipped` aqui não valia (a NSView não é
            // invertida) e a imagem descia ou subia vários semitons conforme a janela de alturas.
            let root = CALayer()
            root.isGeometryFlipped = false
            root.masksToBounds = true
            layer = root
            wantsLayer = true
            container.anchorPoint = .zero
            container.position = .zero
            root.addSublayer(container)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// O tamanho mudou (a janela, o mixer, o Z): a mesma janela de tempo na largura nova.
        override func layout() {
            super.layout()
            if let last { show(image: shown, spectrum: last.spectrum, start: last.start, span: last.span, pitches: last.pitches) }
        }

        func show(image: CGImage?, spectrum: Spectrum?, start: Double, span: Double, pitches: ClosedRange<Double>) {
            last = (spectrum, start, span, pitches)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if image !== shown {
                shown = image
                container.sublayers?.forEach { $0.removeFromSuperlayer() }
                if let image {
                    var first = 0
                    while first < image.width {
                        let width = min(Self.tileFrames, image.width - first)
                        if let piece = image.cropping(to: CGRect(x: first, y: 0, width: width, height: image.height)) {
                            let tile = CALayer()
                            tile.contents = piece
                            tile.contentsGravity = .resize
                            tile.magnificationFilter = .linear
                            tile.minificationFilter = .linear
                            tile.isOpaque = true
                            tile.frame = CGRect(x: first, y: 0, width: width, height: image.height)
                            container.addSublayer(tile)
                        }
                        first += width
                    }
                }
                placed = nil
            }
            guard let spectrum, let image, bounds.width > 0, bounds.height > 0, span > 0 else {
                container.isHidden = true
                return
            }
            container.isHidden = false
            if let placed, placed.start == start, placed.span == span, placed.pitches == pitches, placed.size == bounds.size {
                return
            }
            placed = (start, span, pitches, bounds.size)
            // Conteúdo: x em quadros; y em pixels da imagem contados de baixo (a camada desenha a imagem em pé, com o y
            // para cima), e a altura mais grave da janela vai para a base da tela. Tela: a janela de tempo na largura e a
            // de alturas na altura.
            let rowScale = Double(image.height) / Double(spectrum.rows)
            // O centro do pixel da linha r fica em r · rowScale + ½ (`SpectrumPalette`: a linha de cima é a mais aguda).
            let yBottom = spectrum.row(pitch: pitches.lowerBound) * rowScale + 0.5
            let yRange = (spectrum.row(pitch: pitches.upperBound) - spectrum.row(pitch: pitches.lowerBound)) * rowScale
            let sx = spectrum.hop / span * bounds.width
            let sy = bounds.height / max(1, yRange)
            var transform = CATransform3DMakeTranslation(-start / span * bounds.width, -yBottom * sy, 0)
            transform = CATransform3DScale(transform, sx, sy, 1)
            container.transform = transform
        }
    }
}
