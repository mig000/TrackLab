import AppKit
import SwiftUI
import TrackLabCore

/// O mapa da música, sob a barra: a música inteira numa linha. As partes (as seções do Guitar Pro) nas cores delas, os
/// trechos de estudo como chaves em cima (com recorde → meta; a ativa cheia), os compassos conferidos em verde embaixo,
/// as suspeitas em vermelho, o loop e a agulha. Um clique leva a música até ali (numa chave, liga o trecho); arrastar
/// marca o loop, preso nas batidas; o botão direito numa chave tem o menu do trecho. Na ponta, "+ Trecho do loop".
struct SongMapView: View {
    let model: SongModel
    @Local private var drag: (from: Double, to: Double)?
    @Local private var renaming: StudySection?
    @Local private var newName = ""
    @Local private var tagging: StudySection?
    @Local private var tagText = ""

    static let height = 40.0

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                // O mapa só se redesenha quando muda; a agulha, que anda um pixel a cada segundo ou dois, fica numa camada
                // própria e a 10 quadros por segundo (o mapa inteiro a cada quadro tirava tempo da Fita e da TAB).
                let _ = (model.activeSectionID, model.checkedBars, model.engine.loop, model.grid, model.scoreTrack,
                         model.sections, model.suspects, model.markers, drag.map { [$0.from, $0.to] })
                Canvas { canvas, size in draw(&canvas, size: size) }
                    .overlay {
                        TimelineView(.animation(minimumInterval: 0.1, paused: !model.engine.isPlaying)) { context in
                            let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
                            Canvas { canvas, size in
                                let x = model.engine.songTime(atHost: host) / duration * size.width
                                canvas.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
                            }
                        }
                    }
                .contentShape(Rectangle())
                .gesture(gesture(width: geometry.size.width))
                .background(RightClickCatcher { point, view in
                    guard let section = section(at: point, width: geometry.size.width) else { return false }
                    showMenu(for: section, at: point, in: view)
                    return true
                })
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            Menu {
                ForEach(SectionKind.allCases) { kind in
                    Button { model.addSectionFromLoop(kind: kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                }
                if model.sections.isEmpty, !model.markers.isEmpty {
                    Divider()
                    Button("Um trecho por parte da música") { model.addSectionsFromMarkers() }
                }
            } label: {
                Label("Trecho do loop", systemImage: "plus")
            } primaryAction: {
                model.addSectionFromLoop()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.engine.loop == nil && !(model.sections.isEmpty && !model.markers.isEmpty))
            .help("Guarda o loop de agora como trecho (clique) ou como lick, solo, riff… (seta); marque o loop "
                  + "arrastando no mapa ou na Fita, ou com L")
        }
        .alert("Renomear trecho", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let renaming { model.rename(renaming, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Etiquetas", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("blues, bend, pentatônica", text: $tagText)
            Button("Guardar") { if let tagging { model.setTags(tagging, tagText) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let known = model.knownTags
            Text(known.isEmpty ? "Separadas por vírgula." : "Separadas por vírgula. Já usadas: \(known.joined(separator: ", "))")
        }
    }

    private var duration: Double { max(model.engine.duration, 1) }

    private func seconds(at x: Double, width: Double) -> Double {
        min(max(0, x / max(width, 1) * duration), duration)
    }

    /// A chave de trecho sob o ponto (os 12 pontos de cima).
    private func section(at point: CGPoint, width: Double) -> StudySection? {
        guard point.y <= 12 else { return nil }
        let t = seconds(at: point.x, width: width)
        return model.sections.first { section in
            model.grid.seconds(at: section.from) <= t && t <= model.grid.seconds(at: section.to)
        }
    }

    private func gesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) > 3 {
                    drag = (seconds(at: value.startLocation.x, width: width), seconds(at: value.location.x, width: width))
                }
            }
            .onEnded { value in
                defer { drag = nil }
                if let drag, abs(value.translation.width) > 3 {
                    if let range = LoopRegion.snapped(drag.from, drag.to, grid: model.grid, duration: model.engine.duration) {
                        model.setLoop(range, seekToStart: true)
                    }
                    return
                }
                if let section = section(at: value.location, width: width) {
                    if model.activeSectionID == section.id { model.deactivateSection() } else { model.activate(section) }
                    return
                }
                model.engine.seek(to: seconds(at: value.location.x, width: width))
            }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        func x(_ t: Double) -> Double { t / duration * width }
        // As partes, nas cores delas; o nome quando cabe.
        for part in model.songParts() {
            let x0 = x(part.from)
            let x1 = x(part.to)
            let rect = CGRect(x: x0 + 0.5, y: 11, width: max(1, x1 - x0 - 1), height: 16)
            let color = Color(red: part.color.0, green: part.color.1, blue: part.color.2)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.85)))
            if rect.width > 34 {
                var clipped = context
                clipped.clip(to: Path(rect.insetBy(dx: 3, dy: 0)))
                clipped.draw(CanvasLabel.image(part.name, size: 9, weight: .semibold, color: .white, dark: true),
                             at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
            }
        }
        // Os compassos conferidos: verde embaixo.
        let bars = model.grid.bars
        var checked = Path()
        for bar in model.checkedBars where bar >= 1 && bar < bars.count {
            checked.addRect(CGRect(x: x(bars[bar - 1]), y: size.height - 6, width: max(1, x(bars[bar]) - x(bars[bar - 1])), height: 3))
        }
        context.fill(checked, with: .color(.green.opacity(0.9)))
        // As suspeitas: traços vermelhos (sem passar de algumas centenas por quadro).
        var suspects = Path()
        for suspect in model.suspects(track: model.scoreTrack).prefix(400) {
            suspects.addRect(CGRect(x: x(suspect.seconds) - 0.5, y: size.height - 11, width: 1.5, height: 4))
        }
        context.fill(suspects, with: .color(Color(red: 1, green: 0.36, blue: 0.36)))
        // Os trechos de estudo: chaves em cima, a ativa cheia.
        for section in model.sections {
            let x0 = x(model.grid.seconds(at: section.from))
            let x1 = x(model.grid.seconds(at: section.to))
            let active = model.activeSectionID == section.id
            var bracket = Path()
            bracket.move(to: CGPoint(x: x0, y: 8))
            bracket.addLine(to: CGPoint(x: x0, y: 1.5))
            bracket.addLine(to: CGPoint(x: x1, y: 1.5))
            bracket.addLine(to: CGPoint(x: x1, y: 8))
            if active {
                context.fill(Path(CGRect(x: x0, y: 1, width: x1 - x0, height: 9)), with: .color(Color.accentColor.opacity(0.25)))
            }
            context.stroke(bracket, with: .color(active ? Color.accentColor : Color.accentColor.opacity(0.7)), lineWidth: active ? 2 : 1.5)
            if x1 - x0 > 50 {
                let label = "\(section.name) · \(section.best.map { "\($0)" } ?? "–") → \(section.goal) %"
                var clipped = context
                clipped.clip(to: Path(CGRect(x: x0 + 2, y: 0, width: x1 - x0 - 4, height: 11)))
                clipped.draw(Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.accentColor),
                             at: CGPoint(x: x0 + 4, y: 5), anchor: .leading)
            }
        }
        // O loop (e o que está sendo arrastado).
        let loops = [model.engine.loop, drag.map { min($0.from, $0.to)...max($0.from, $0.to) }].compactMap { $0 }
        for range in loops {
            let rect = CGRect(x: x(range.lowerBound), y: 2, width: max(2, x(range.upperBound) - x(range.lowerBound)), height: size.height - 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(0.18)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.orange.opacity(0.9)), lineWidth: 1.2)
        }
    }

    /// O menu do trecho (o botão direito na chave): renomear, meta, tipo, etiquetas, favorito, apagar.
    private func showMenu(for section: StudySection, at point: CGPoint, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addTitle(section.name, detail: "\(section.kind.label) · recorde \(section.best.map { "\($0) %" } ?? "–") · meta \(section.goal) %")
        menu.addSeparator()
        menu.add(model.activeSectionID == section.id ? "Soltar o trecho" : "Estudar este trecho") {
            if model.activeSectionID == section.id { model.deactivateSection() } else { model.activate(section) }
        }
        menu.addSeparator()
        let rename = $renaming
        let name = $newName
        menu.add("Renomear…") {
            name.wrappedValue = section.name
            rename.wrappedValue = section
        }
        menu.addSubmenu("Meta") { sub in
            for goal in [80, 90, 100, 110, 120] {
                sub.add("\(goal) %", checked: goal == section.goal) { model.setGoal(section, goal) }
            }
        }
        menu.addSubmenu("Tipo") { sub in
            for kind in SectionKind.allCases {
                sub.add(kind.label, checked: kind == section.kind) { model.setKind(section, kind) }
            }
        }
        let tags = $tagging
        let text = $tagText
        menu.add("Etiquetas…") {
            text.wrappedValue = section.tags.joined(separator: ", ")
            tags.wrappedValue = section
        }
        menu.add(section.favorite ? "Tirar dos favoritos" : "Favorito") { model.toggleFavorite(section) }
        menu.addSeparator()
        menu.add("Apagar") { model.delete(section) }
        menu.popUp(positioning: nil, at: point, in: view)
    }
}
