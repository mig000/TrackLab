import AppKit
import QuartzCore
import SwiftUI
import TrackLabCore

/// O espectro da Fita na GPU: a imagem (um pixel por quadro, `SpectrumPalette.rowScale` por linha) cortada em ladrilhos
/// de `tileFrames` quadros (abaixo do limite de textura da placa), cada um uma CALayer enviada à placa uma vez. A cada
/// quadro só muda a transformação do contêiner (onde a janela de tempo e a de alturas caem na tela) e o Core Animation
/// compõe na GPU, com interpolação bilinear. Antes, o Canvas redesenhava a imagem esticada na CPU a cada quadro e a
/// rolagem engasgava no iMac.
///
/// A Tinta (3/11): por cima da imagem violeta, a mesma em âmbar, cada ladrilho com uma máscara feita das linhas das
/// notas (`LensGlow`): onde a TAB tem nota, a energia do som acende em âmbar. A máscara fica nas coordenadas da imagem
/// e anda com a mesma transformação; só é refeita quando as notas ou as curvas mudam.
struct SpectrumLayerView: NSViewRepresentable {
    let image: CGImage?
    let warm: CGImage?
    let glow: LensGlow?
    /// O começo da janela (segundos), quantos segundos ela mostra e a faixa de alturas.
    let start: Double
    let span: Double
    let pitches: ClosedRange<Double>
    let spectrum: Spectrum?

    func makeNSView(context: Context) -> HostView { HostView() }

    func updateNSView(_ view: HostView, context: Context) {
        view.show(image: image, spectrum: spectrum, start: start, span: span, pitches: pitches)
        view.light(warm: warm, glow: glow)
    }

    final class HostView: NSView {
        static let tileFrames = 4096
        private let container = CALayer()
        /// A âmbar, por cima da violeta, com a mesma transformação.
        private let warmContainer = CALayer()
        private weak var shown: CGImage?
        private weak var shownWarm: CGImage?
        private var warmTiles: [(layer: CALayer, first: Int, width: Int)] = []
        private var glowVersion = -1
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
            for layer in [container, warmContainer] {
                layer.anchorPoint = .zero
                layer.position = .zero
                root.addSublayer(layer)
            }
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
                warmContainer.isHidden = true
                return
            }
            container.isHidden = false
            warmContainer.isHidden = false
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
            warmContainer.transform = transform
        }

        /// A âmbar: os ladrilhos (uma vez por imagem) e as máscaras (quando as linhas mudam).
        func light(warm: CGImage?, glow: LensGlow?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if warm !== shownWarm {
                shownWarm = warm
                warmContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
                warmTiles = []
                glowVersion = -1
                if let warm {
                    var first = 0
                    while first < warm.width {
                        let width = min(Self.tileFrames, warm.width - first)
                        if let piece = warm.cropping(to: CGRect(x: first, y: 0, width: width, height: warm.height)) {
                            let tile = CALayer()
                            tile.contents = piece
                            tile.contentsGravity = .resize
                            tile.magnificationFilter = .linear
                            tile.minificationFilter = .linear
                            tile.frame = CGRect(x: first, y: 0, width: width, height: warm.height)
                            warmContainer.addSublayer(tile)
                            warmTiles.append((tile, first, width))
                        }
                        first += width
                    }
                }
            }
            warmContainer.isHidden = glow == nil || container.isHidden
            guard let glow, glow.version != glowVersion else { return }
            glowVersion = glow.version
            for tile in warmTiles {
                tile.layer.mask = Self.mask(glow, first: tile.first, width: tile.width,
                                            height: Double(tile.layer.bounds.height))
            }
        }

        /// A máscara de um ladrilho: as linhas das notas que passam por ele, um miolo cheio de 0,9 semitom e uma borda
        /// de 1,7 semitom pela metade (a âmbar entra suave, sem um corte duro na beira da nota).
        static func mask(_ glow: LensGlow, first: Int, width: Int, height: Double) -> CALayer {
            let path = CGMutablePath()
            let from = Double(first) - 20
            let to = Double(first + width) + 20
            for line in glow.lines {
                guard let a = line.first, let b = line.last, b.x >= from, a.x <= to, line.count > 1 else { continue }
                path.addLines(between: line.map { CGPoint(x: $0.x - Double(first), y: $0.y) })
            }
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: Double(width), height: height)
            for (scale, alpha) in [(1.7, 0.45), (0.9, 1.0)] {
                let shape = CAShapeLayer()
                shape.frame = layer.bounds
                shape.path = path
                shape.fillColor = nil
                shape.strokeColor = CGColor(gray: 0, alpha: alpha)
                shape.lineWidth = glow.semitone * scale
                shape.lineCap = .round
                shape.lineJoin = .round
                layer.addSublayer(shape)
            }
            return layer
        }
    }
}

/// As linhas das notas da pista principal na Lente, nas coordenadas da imagem do espectro (`SongModel.lensGlow`).
struct LensGlow {
    let version: Int
    let lines: [[CGPoint]]
    /// Quantos pixels da imagem são um semitom (a espessura do brilho).
    let semitone: Double
}
