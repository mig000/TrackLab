import SwiftUI
import TrackLabCore

/// Trechos (Fase 3b): todos os trechos de todas as músicas numa biblioteca de partes para estudo. Busca sem acento pelo
/// começo das palavras (nome, tipo, etiquetas, música, artista, afinação), filtros por tipo, etiqueta e favorito, e
/// ordens; um clique abre a música com o loop do trecho, e o menu muda tipo, etiquetas e favorito ali mesmo.
struct SectionsView: View {
    let library: LibraryModel
    @Local private var query = ""
    @Local private var kinds: Set<SectionKind> = []
    @Local private var tags: Set<String> = []
    @Local private var favoritesOnly = false
    @Local private var order = SectionLibrary.Order.recent
    @Local private var tagging: SectionItem?
    @Local private var tagText = ""

    var body: some View {
        let all = library.sectionItems
        let shown = SectionLibrary.sorted(SectionLibrary.filter(all, query: query, kinds: kinds, tags: tags,
                                                                favoritesOnly: favoritesOnly), by: order)
        VStack(alignment: .leading, spacing: 0) {
            header(all: all, shown: shown.count)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            if all.isEmpty {
                empty
            } else if shown.isEmpty {
                Text("Nenhum trecho com esses filtros.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { item in
                    SectionRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { library.open(item) }
                        .contextMenu { menu(item) }
                }
                .listStyle(.inset)
            }
        }
        .alert("Etiquetas", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("blues, bend, pentatônica", text: $tagText)
            Button("Guardar") {
                if let tagging {
                    let text = tagText
                    library.edit(tagging) { $0.tags = StudySection.tags(from: text) }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let known = SectionLibrary.topTags(all, limit: 20)
            Text(known.isEmpty ? "Separadas por vírgula." : "Separadas por vírgula. Já usadas: \(known.joined(separator: ", "))")
        }
    }

    private func header(all: [SectionItem], shown: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trechos").font(.largeTitle.weight(.bold))
                Text(shown == all.count ? "\(all.count)" : "\(shown) de \(all.count)")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Ordem", selection: $order) {
                    ForEach(SectionLibrary.Order.allCases) { order in Text(order.label).tag(order) }
                }
                .fixedSize()
            }
            TextField("Buscar: nome, tipo, etiqueta, música, artista, afinação", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 520)
            HStack(spacing: 6) {
                Toggle(isOn: $favoritesOnly) { Label("Favoritos", systemImage: "star.fill") }
                    .toggleStyle(.button)
                Divider().frame(height: 16)
                ForEach(SectionKind.allCases) { kind in
                    let count = all.filter { $0.section.kind == kind }.count
                    if count > 0 {
                        Toggle(isOn: Binding(get: { kinds.contains(kind) },
                                             set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } })) {
                            Label("\(kind.label) \(count)", systemImage: kind.symbol)
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            .controlSize(.small)
            let top = SectionLibrary.topTags(all)
            if !top.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tag").foregroundStyle(.secondary)
                    ForEach(top, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(get: { tags.contains(tag) },
                                                  set: { on in if on { tags.insert(tag) } else { tags.remove(tag) } }))
                            .toggleStyle(.button)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func menu(_ item: SectionItem) -> some View {
        Button("Abrir na música") { library.open(item) }
        Menu("Tipo") {
            ForEach(SectionKind.allCases) { kind in
                Button("\(kind.label)\(kind == item.section.kind ? " ✓" : "")") {
                    library.edit(item) { $0.kind = kind }
                }
            }
        }
        Button("Etiquetas…") {
            tagText = item.section.tags.joined(separator: ", ")
            tagging = item
        }
        Button(item.section.favorite ? "Tirar dos favoritos" : "Favorito") {
            library.edit(item) { $0.favorite.toggle() }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ainda não há trechos.").font(.headline)
            Text("Numa música, marque o loop (arrastando na Fita ou com L) e guarde com \"+ Do loop\": como trecho, lick, "
                 + "solo, riff… Os trechos de todas as músicas aparecem aqui, com etiquetas e favoritos.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SectionRow: View {
    let item: SectionItem

    var body: some View {
        let section = item.section
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: section.kind.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .help(section.kind.label)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(section.name).font(.headline)
                    if section.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    ForEach(section.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text([item.songTitle, item.artist, item.tuning].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(details(section))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(min(section.best ?? 0, section.goal)), total: Double(section.goal))
                    .tint(.orange)
                    .frame(width: 110)
                Text("\(section.best.map { "\($0) %" } ?? "–") → \(section.goal) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(practiced(section))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// Compassos, duração e andamento, os que se sabem.
    private func details(_ section: StudySection) -> String {
        var parts: [String] = []
        if let bars = section.bars { parts.append(bars == 1 ? "1 compasso" : "\(bars) compassos") }
        if let seconds = section.seconds { parts.append(String(format: "%.0f s", seconds)) }
        if let bpm = section.bpm { parts.append("\(Int(bpm.rounded())) bpm") }
        return parts.joined(separator: " · ")
    }

    private func practiced(_ section: StudySection) -> String {
        guard let days = section.daysSincePracticed(now: Date()) else { return "nunca tocado" }
        switch days {
        case 0: return "hoje"
        case 1: return "ontem"
        default: return "há \(days) dias"
        }
    }
}
