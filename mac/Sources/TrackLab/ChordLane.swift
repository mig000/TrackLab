import AppKit
import SwiftUI
import TrackLabCore

/// A barra de acordes, sob a TAB, na escala da Fita: um bloco por acorde com o nome no começo, o que toca realçado, e
/// uma linha laranja embaixo onde o som e as notas discordam (o menu diz o que o som ouve).
/// Um clique leva a música até o acorde e o escolhe; duplo clique renomeia; arrastar a divisa entre dois acordes muda
/// onde a troca cai (na grade de colcheias); arrastar no meio marca o loop; o botão direito tem o menu do acorde.
struct ChordLane: View {
    let model: SongModel
    let span: Double
    @Local private var renaming: ChordSpan?
    @Local private var newName = ""
    /// O arrasto da divisa: o tique de onde a troca saiu e onde ela está agora.
    @Local private var moving: (from: Double, to: Double)?
    @Local private var looping: (from: Double, to: Double)?
    @Local private var lastClick: (from: Double, at: Date)?

    static let height = 22.0

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: !model.engine.isPlaying)) { context in
                let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
                let now = model.engine.songTime(atHost: host)
                Canvas { canvas, size in draw(&canvas, size: size, now: now) }
            }
            .contentShape(Rectangle())
            .gesture(gesture(width: geometry.size.width))
            .background(RightClickCatcher { point, view in
                let seconds = seconds(at: point.x, width: geometry.size.width)
                let tick = model.grid.tick(at: seconds)
                guard let chord = model.chord(atTick: tick) else { return false }
                model.showChordMenu(chord, clickTick: model.chordTick(at: seconds), at: point, in: view) { chord in
                    newName = model.shown(chord.name)
                    renaming = chord
                }
                return true
            })
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .alert("Acorde", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Am7, C/G, F#m…", text: $newName)
            Button("Guardar") { if let renaming { model.renameChord(renaming, to: model.sounding(fromShown: newName)) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if let renaming, !renaming.alternatives.isEmpty {
                Text("As notas também aceitam: \(renaming.alternatives.map(model.shown).joined(separator: ", ")). Vazio é sem acorde."
                     + (model.showingShapes ? " Os nomes são pela forma do capo \(model.capoFret)ª." : ""))
            } else {
                Text("Vazio é sem acorde.")
            }
        }
    }

    private func seconds(at x: Double, width: Double) -> Double {
        model.viewStart(now: model.engine.currentTime) + x / max(width, 1) * span
    }

    /// A troca de acorde a até 5 pontos do x (o tique dela).
    private func change(near x: Double, width: Double) -> Double? {
        let start = model.viewStart(now: model.engine.currentTime)
        return model.chordSpans.dropFirst().first { chord in
            abs((model.grid.seconds(at: chord.from) - start) / span * width - x) <= 5
        }?.from
    }

    private func gesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = abs(value.translation.width) > 3
                if moving == nil, looping == nil, moved {
                    if let tick = change(near: value.startLocation.x, width: width) {
                        moving = (tick, tick)
                    } else {
                        looping = (seconds(at: value.startLocation.x, width: width), 0)
                    }
                }
                if let current = moving {
                    moving = (current.from, model.chordTick(at: seconds(at: value.location.x, width: width)))
                } else if let current = looping {
                    looping = (current.from, seconds(at: value.location.x, width: width))
                }
            }
            .onEnded { value in
                defer {
                    moving = nil
                    looping = nil
                }
                if let moving {
                    model.moveChordChange(from: moving.from, to: moving.to)
                    return
                }
                if let looping {
                    if let range = LoopRegion.snapped(looping.from, looping.to, grid: model.grid, duration: model.engine.duration) {
                        model.setLoop(range, seekToStart: true)
                    }
                    return
                }
                let tick = model.grid.tick(at: seconds(at: value.location.x, width: width))
                guard let chord = model.chord(atTick: tick) else { return }
                // Duplo clique no mesmo acorde: renomear.
                if let last = lastClick, last.from == chord.from, Date().timeIntervalSince(last.at) < 0.4 {
                    lastClick = nil
                    newName = model.shown(chord.name)
                    renaming = chord
                    return
                }
                lastClick = (chord.from, Date())
                model.chosenChord = chord.from
                // A música até o começo do acorde, com a agulha nele: a tela fica onde está.
                let begin = model.grid.seconds(at: chord.from)
                model.seek(to: begin, at: (begin - model.viewStart(now: model.engine.currentTime)) / span)
            }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double) {
        let width = size.width
        let height = size.height
        let start = model.viewStart(now: now)
        let end = start + span
        func x(_ t: Double) -> Double { (t - start) / span * width }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .underPageBackgroundColor).opacity(0.55)))
        if let loop = model.engine.loop {
            context.fill(Path(CGRect(x: x(loop.lowerBound), y: 0, width: x(loop.upperBound) - x(loop.lowerBound), height: height)),
                         with: .color(.orange.opacity(0.1)))
        }
        let grid = model.grid
        let nowTick = grid.tick(at: now)
        let amber = Color(red: 0.96, green: 0.71, blue: 0.27)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // A divisa sendo arrastada: os dois acordes vizinhos com a troca no lugar novo.
        var spans = model.chordSpans
        if let moving, let index = spans.firstIndex(where: { abs($0.from - moving.from) < 0.5 }), index > 0 {
            spans[index - 1].to = moving.to
            spans[index].from = moving.to
        }
        for chord in spans {
            let a = grid.seconds(at: chord.from)
            let b = grid.seconds(at: chord.to)
            guard b > start, a < end else { continue }
            let rect = CGRect(x: x(a) + 1, y: 2, width: max(1, x(b) - x(a) - 2), height: height - 4)
            let playing = chord.from <= nowTick && nowTick < chord.to
            let chosen = model.chosenChord == chord.from
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            if chord.name.isEmpty {
                context.stroke(shape, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            } else {
                context.fill(shape, with: .color(playing ? amber.opacity(0.32) : Color.secondary.opacity(0.1)))
            }
            if chosen {
                context.stroke(shape, with: .color(.accentColor), lineWidth: 1.4)
            } else if playing {
                context.stroke(shape, with: .color(amber.opacity(0.9)), lineWidth: 1)
            }
            // O nome no começo do bloco (o de um acorde que já começou fica preso na borda esquerda, se cabe).
            guard rect.width > 14 else { continue }
            let label = chord.name.isEmpty ? "N.C." : model.shown(chord.name)
            let image = CanvasLabel.image(label, size: 11, weight: playing ? .bold : .semibold,
                                          color: chord.name.isEmpty ? .tertiaryLabelColor : .labelColor, dark: dark)
            var clipped = context
            clipped.clip(to: Path(rect.insetBy(dx: 2, dy: 0)))
            let left = max(rect.minX + 4, min(4, rect.maxX - 30))
            clipped.draw(image, at: CGPoint(x: left, y: rect.midY), anchor: .leading)
            // O som e as notas discordam: uma linha laranja embaixo do bloco.
            if chord.disputed {
                context.fill(Path(roundedRect: CGRect(x: rect.minX + 2, y: rect.maxY - 2, width: rect.width - 4, height: 2),
                                  cornerRadius: 1), with: .color(.orange))
            }
            // A correção ganha um ponto no canto; o escrito na TAB, um traço embaixo.
            if chord.source == .edited {
                context.fill(Path(ellipseIn: CGRect(x: rect.maxX - 6, y: rect.minY + 2, width: 4, height: 4)), with: .color(.accentColor))
            } else if chord.source == .written {
                context.fill(Path(CGRect(x: rect.minX + 4, y: rect.maxY - 2, width: min(14, rect.width - 8), height: 1)),
                             with: .color(.secondary.opacity(0.6)))
            }
        }
        // O motor ainda ouvindo a música (a primeira vez, ~1 min).
        if model.hearingChords {
            let label = CanvasLabel.image("ouvindo os acordes…", size: 10, color: .secondaryLabelColor, dark: dark)
            context.draw(label, at: CGPoint(x: width - 6, y: height / 2), anchor: .trailing)
        }
        // O loop sendo marcado.
        if let looping {
            let a = min(looping.from, looping.to)
            let b = max(looping.from, looping.to)
            context.stroke(Path(CGRect(x: x(a), y: 1, width: x(b) - x(a), height: height - 2)), with: .color(.orange), lineWidth: 1)
        }
    }
}
