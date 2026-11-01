import AppKit
import SwiftUI
import TrackLabCore

/// O botão direito, em qualquer modo: na nota, a edição rápida (as articulações mais usadas e a casa como controles na
/// cabeça do menu; Ouvir, Encaixar, as Leituras, Bend, Duração, Mover no tempo, meio tom, loop, reconhecer, recortar,
/// copiar, colar, apagar); no número do compasso (na TAB, na Onda ou na Lente), o compasso: loop, trecho, Conferido,
/// sincronizar e corrigir pelo som, pôr e apagar, fórmula. Escolher a nota liga a edição.
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire(_ sender: Any?) { run() }
}

@MainActor
extension NSMenu {
    @discardableResult
    func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], checked: Bool = false,
             enabled: Bool = true, subtitle: String? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = action
        item.representedObject = action
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        if let subtitle { item.subtitle = subtitle }
        addItem(item)
        return item
    }

    /// A cabeça do menu: o que é (em negrito) e onde está, sem ação.
    func addTitle(_ title: String, detail: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        if let detail {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        item.attributedTitle = text
        item.isEnabled = false
        addItem(item)
    }

    func addSeparator() { addItem(.separator()) }

    @discardableResult
    func addSubmenu(_ title: String, subtitle: String? = nil, _ fill: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let subtitle { item.subtitle = subtitle }
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        fill(menu)
        item.submenu = menu
        addItem(item)
        return item
    }

    /// Uma linha de controles do SwiftUI dentro do menu (as articulações, a casa), como as cores de etiqueta do Finder.
    func addView<V: View>(_ view: V, height: CGFloat, width: CGFloat = 318) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let item = NSMenuItem()
        item.view = host
        addItem(item)
    }
}

extension SongModel {
    /// O botão direito numa nota (da TAB, ou da Lente): a nota fica escolhida (a edição liga se não estava) e o menu
    /// abre quando a página confirma a escolha.
    func contextMenu(forTrack track: Int, tick: Double, string: Int, at point: CGPoint, in view: NSView) {
        if !editingTab { editingTab = true }
        if let current = tabSelection, current.track == track, current.string == string,
           let own = current.ownTick ?? current.tick, abs(own - tick) < 1 {
            showNoteMenu(current, at: point, in: view)
            return
        }
        pendingMenu = (point, view)
        bridge.edit("select", ["track": track, "tick": tick, "string": string])
    }

    /// O ponto chega com o y de cima para baixo (a página e os pegadores do botão direito); numa view que não é assim, vira.
    func menuPoint(_ point: CGPoint, in view: NSView) -> CGPoint {
        view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
    }

    func showNoteMenu(_ note: TabSelection, at point: CGPoint, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let place = [note.place, note.figure, note.voice > 1 ? "voz \(note.voice)" : nil].compactMap { $0 }.joined(separator: " · ")
        let sound = soundSummary
        menu.addTitle(note.count > 1 ? "\(note.count) notas · \(note.span ?? "")" : "\(note.pitchName) · casa \(note.fret), corda \(note.string)",
                      detail: [place.isEmpty ? nil : place, sound].compactMap { $0 }.joined(separator: " · "))
        menu.addView(ArticulationChips(model: self), height: 34)
        if note.count == 1 { menu.addView(FretAndStrings(model: self), height: 34) }
        menu.addSeparator()
        menu.add("Ouvir", key: "o") { [weak self] in self?.listenSelection() }
        menu.add("Ouvir sintetizada", key: "o", modifiers: .option) { [weak self] in self?.hearSelection(synth: true) }
        menu.addSeparator()
        menu.add("Encaixar no som", key: "f", enabled: sound != nil, subtitle: sound) { [weak self] in self?.fitToSound() }
        if let sheet = selectedReadings() {
            menu.addSubmenu("Leituras") { sub in
                for card in sheet.cards {
                    sub.add("\(card.reading.name) · \(Int((card.closeness * 100).rounded())) %", key: card.id < 4 ? "\(card.id + 1)" : "",
                            modifiers: .option, checked: card.current) { [weak self] in self?.chooseReading(card.id) }
                }
            }
        } else if let positions = selectedPositions() {
            menu.addSubmenu("Posição no braço") { sub in
                for card in positions {
                    sub.add(card.current ? "Como está" : "Casas \(card.frets.lowerBound)–\(card.frets.upperBound)",
                            checked: card.current) { [weak self] in self?.choosePosition(card.id) }
                }
            }
        }
        menu.addSeparator()
        let form = note.bendForm
        menu.addSubmenu("Bend", subtitle: form?.spoken) { sub in
            let heights: [(Int, String)] = [(1, "¼ de tom"), (2, "½ tom"), (3, "¾ de tom"), (4, "1 tom"), (6, "1½ tom"), (8, "2 tons")]
            let current = form.map { $0.kind.usesTop ? $0.top : $0.pre } ?? 0
            for (quarters, name) in heights {
                sub.add(name, key: quarters == 2 && form == nil ? "b" : "", checked: form != nil && current == quarters) { [weak self] in
                    guard let self else { return }
                    let base = form ?? BendForm.make(.bend, carried: note.carried)
                    self.setBend(base.with(height: quarters))
                }
            }
            sub.addSeparator()
            var kinds: [BendForm.Kind] = [.bend, .bendRelease, .prebend, .prebendBend, .prebendRelease]
            if note.carried > 0 { kinds.append(.release) }
            for kind in kinds {
                sub.add(kind.label, key: kind == .bendRelease ? "b" : "", modifiers: kind == .bendRelease ? .shift : [],
                        checked: form?.kind == kind) { [weak self] in
                    self?.setBend(BendForm.make(kind, from: form, carried: note.carried))
                }
            }
            sub.addSeparator()
            sub.add("Tirar o bend", enabled: form != nil) { [weak self] in self?.setBend(nil) }
        }
        let on = Set(note.techniques)
        menu.addSubmenu("Mais articulações") { sub in
            for (index, group) in TabEditPanel.groups.enumerated() {
                if index > 0 { sub.addSeparator() }
                for item in group.items {
                    sub.add(item.label.count <= 4 ? item.help.components(separatedBy: " (").first ?? item.label : item.label,
                            key: item.shortcut?.lowercased() ?? "", checked: on.contains(item.key)) { [weak self] in
                        self?.toggleTechnique(item.key)
                    }
                }
            }
        }
        menu.addSubmenu("Duração", subtitle: note.figure) { sub in
            for figure in SongModel.figures {
                sub.add(figure.name.prefix(1).uppercased() + figure.name.dropFirst(), checked: note.base == figure.ticks) { [weak self] in
                    self?.setFigure(base: figure.ticks)
                }
            }
            sub.addSeparator()
            sub.add("Pontuada", key: ".", checked: note.dotted) { [weak self] in self?.setFigure(dotted: !note.dotted) }
            sub.add("Tercina", key: "t", checked: note.triplet) { [weak self] in self?.setFigure(triplet: !note.triplet) }
            sub.addSeparator()
            sub.add("Virar pausa", key: "\u{8}", modifiers: .shift) { [weak self] in self?.tabEdit("rest") }
        }
        menu.add("Dividir em duas ligadas", key: "/") { [weak self] in self?.splitNote() }
        menu.addSubmenu("Mover no tempo") { sub in
            sub.add("Mais cedo", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: .option) { [weak self] in self?.shiftSelected(-1) }
            sub.add("Mais tarde", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .option) { [weak self] in self?.shiftSelected(1) }
            sub.addSeparator()
            sub.add("Barras de duração", key: "d", checked: showDurations) { [weak self] in self?.showDurations.toggle() }
            sub.addSeparator()
            for grid in SongModel.grids {
                sub.add("Grade \(grid.name)", checked: gridTicks == grid.ticks) { [weak self] in self?.gridTicks = grid.ticks }
            }
        }
        menu.addSeparator()
        menu.add("Meio tom acima", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: .option) { [weak self] in self?.tabEdit("transpose", 1) }
        menu.add("Meio tom abaixo", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .option) { [weak self] in self?.tabEdit("transpose", -1) }
        menu.addSeparator()
        menu.add(note.count > 1 ? "Loop nestas notas" : "Loop nesta nota", key: "l") { [weak self] in self?.loopSelection() }
        menu.add("Reconhecer este trecho no espectro…", key: "r", modifiers: [.option, .command]) { [weak self] in self?.armRegionSelection() }
        menu.addSeparator()
        menu.add("Recortar", key: "x", modifiers: .command) { [weak self] in self?.copyTab(cut: true) }
        menu.add("Copiar", key: "c", modifiers: .command) { [weak self] in self?.copyTab(cut: false) }
        menu.add("Colar", key: "v", modifiers: .command) { [weak self] in self?.pasteTab() }
        menu.add("Apagar", key: "\u{8}") { [weak self] in self?.tabEdit("delete") }
        menu.popUp(positioning: nil, at: menuPoint(point, in: view), in: view)
    }

    /// O menu do compasso (`index`: 0 é o primeiro).
    func showBarMenu(index: Int, signature: String?, section: String?, at point: CGPoint, in view: NSView) {
        let number = index + 1
        let menu = NSMenu()
        menu.autoenablesItems = false
        let part = section ?? (grid.barTicks.indices.contains(index) ? partName(atTick: grid.barTicks[index]) : nil)
        let checked = checkedBars.contains(number)
        let offset = lensVisible ? barOffsets()[index] : nil
        let offsetText = offset.map { "o som chega \(Int((abs($0) * 1000).rounded())) ms \($0 > 0 ? "depois" : "antes")" }
        menu.addTitle([ "Compasso \(number)", signature, part ].compactMap { $0 }.joined(separator: " · "),
                      detail: [checked ? "conferido" : nil, offsetText].compactMap { $0 }.joined(separator: " · "))
        menu.addSeparator()
        menu.add("Loop no compasso", key: "l") { [weak self] in self?.loopBar(number) }
        menu.addSubmenu("Guardar como trecho") { sub in
            for kind in SectionKind.allCases {
                sub.add(kind.label) { [weak self] in
                    self?.loopBar(number)
                    self?.addSectionFromLoop(kind: kind)
                }
            }
        }
        menu.addSeparator()
        menu.add("Conferido", key: "c", checked: checked) { [weak self] in self?.toggleChecked(bars: [number]) }
        menu.add("Sincronizar pelo som", key: "a", enabled: offset != nil, subtitle: offset.map { "\($0 > 0 ? "+" : "−")\(Int((abs($0) * 1000).rounded())) ms" }) { [weak self] in
            self?.syncBarToSound(bar: number)
        }
        menu.add("Corrigir as notas pelo som", key: "f", modifiers: .shift) { [weak self] in self?.correctBar(number) }
        menu.addSeparator()
        menu.add("Pôr um compasso antes") { [weak self] in self?.editBar("insert-before", index: index) }
        menu.add("Pôr um compasso depois") { [weak self] in self?.editBar("insert-after", index: index) }
        menu.addSubmenu("Fórmula", subtitle: signature) { sub in
            for (numerator, denominator) in [(4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (5, 4), (7, 8)] {
                sub.add("\(numerator)/\(denominator)", checked: signature == "\(numerator)/\(denominator)") { [weak self] in
                    self?.editBar("signature", index: index, numerator: numerator, denominator: denominator)
                }
            }
        }
        menu.add("Apagar o compasso") { [weak self] in self?.editBar("delete", index: index) }
        menu.addSeparator()
        menu.add("Escolher as notas do compasso") { [weak self] in self?.selectBar(index) }
        menu.add("Reconhecer o compasso no espectro…") { [weak self] in self?.armRegionSelection() }
        menu.popUp(positioning: nil, at: menuPoint(point, in: view), in: view)
    }
}

/// As oito articulações mais usadas, como chips que ligam e desligam (a ligada, o ligado, o slide, o bend, o vibrato,
/// o palm mute, o let ring e a nota morta).
private struct ArticulationChips: View {
    let model: SongModel
    static let keys = ["tie", "hammer", "slide-legato", "vibrato", "palm-mute", "let-ring", "dead", "harmonic-natural"]

    var body: some View {
        let on = Set(model.tabSelection?.techniques ?? [])
        let items = TabEditPanel.groups.flatMap(\.items)
        HStack(spacing: 3) {
            ForEach(Self.keys, id: \.self) { key in
                if let item = items.first(where: { $0.key == key }) {
                    Toggle(isOn: Binding(get: { on.contains(key) }, set: { _ in model.toggleTechnique(key) })) {
                        if let icon = item.icon {
                            NotationIconView(icon: icon).frame(maxWidth: .infinity).accessibilityLabel(item.label)
                        } else {
                            Text(item.label).frame(maxWidth: .infinity)
                        }
                    }
                    .toggleStyle(.button)
                    .help(item.help)
                }
            }
            let bend = model.tabSelection?.bendForm
            Button { model.cycleBendHeight() } label: {
                Text(bend.map { "↑" + BendForm.name($0.kind.usesTop ? $0.top : $0.pre) } ?? "↑")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(bend == nil ? nil : .orange)
            .help("Bend: a altura (B); ⇧B o tipo; o submenu tem tudo")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
    }
}

/// A casa (− +) e a corda da nota (1 é a mais aguda), com a casa em que a mesma altura cai em cada uma.
private struct FretAndStrings: View {
    let model: SongModel

    var body: some View {
        let selection = model.tabSelection
        let frets = selection?.strings ?? []
        HStack(spacing: 4) {
            Text("Casa").font(.caption).foregroundStyle(.secondary)
            Button { model.tabEdit("transpose", -1) } label: { Image(systemName: "minus") }
                .disabled((selection?.fret ?? 0) <= 0)
            Text(selection.map { "\($0.fret)" } ?? "–").font(.callout.weight(.semibold).monospacedDigit()).frame(minWidth: 22)
            Button { model.tabEdit("transpose", 1) } label: { Image(systemName: "plus") }
                .disabled((selection?.fret ?? TabEditPanel.maxFret) >= TabEditPanel.maxFret)
            Text("Corda").font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
            ForEach(1...max(1, frets.count), id: \.self) { string in
                let fret = string <= frets.count ? frets[string - 1] : nil
                if selection?.string == string {
                    Button {} label: { Text("\(string)").frame(minWidth: 16) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                } else {
                    Button { if let selection { model.tabEdit("string", selection.string - string) } } label: {
                        Text("\(string)").frame(minWidth: 16)
                    }
                    .buttonStyle(.bordered)
                    .disabled(fret == nil)
                    .help(fret.map { "Corda \(string), casa \($0)" } ?? "A nota não cabe na corda \(string)")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
    }
}
