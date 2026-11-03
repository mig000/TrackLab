import SwiftUI
import TrackLabCore

/// Revisar (o Editar no modo de conferir): as suspeitas da pista uma por vez, em ordem de tempo. ⏎ aceita o que o som
/// diz (o F), ⌫ dispensa (a nota fica como está e a suspeita sai da fila, guardada por música), → pula e ← volta.
extension SongModel {
    /// A chave de uma suspeita dispensada: a pista, o tique e a corda da nota (num som sem nota, o instante e a altura).
    func suspectKey(_ suspect: Suspect, track: Int) -> String {
        if let note = suspect.note { return "\(track):\(Int(note.tick)):\(note.string)" }
        return "\(track):s\(Int((suspect.seconds * 100).rounded())):\(suspect.pitch)"
    }

    var dismissedKey: String { "dispensadas.\(id)" }

    func loadDismissed() {
        dismissedSuspects = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    private func saveDismissed() {
        UserDefaults.standard.set(dismissedSuspects.sorted(), forKey: dismissedKey)
    }

    /// A suspeita em que a revisão está: a da nota escolhida, ou a do cursor de inserção num som sem nota.
    var reviewCurrent: (suspect: Suspect, index: Int, count: Int)? {
        let track = scoreTrack
        let list = suspects(track: track)
        if let (note, chosen) = selectedScoreNote(), chosen == track,
           let index = list.firstIndex(where: { $0.note == note }) {
            return (list[index], index, list.count)
        }
        if tabCaret != nil, let at = reviewSoundAt,
           let index = list.firstIndex(where: { $0.note == nil && abs($0.seconds - at) < 0.001 }) {
            return (list[index], index, list.count)
        }
        return nil
    }

    /// Liga o Revisar: a edição e a Lente (as suspeitas vêm das curvas dela) e vai à primeira suspeita depois da agulha.
    func startReview() {
        if !editingTab { editingTab = true }
        reviewing = true
        if !lensVisible { lensVisible = true }
        if reviewCurrent == nil { nextSuspect(1) }
    }

    /// ⏎: o que o som diz entra na TAB (o F), e a revisão segue para a próxima.
    func reviewAccept() {
        guard let current = reviewCurrent else {
            nextSuspect(1)
            return
        }
        if current.suspect.note == nil {
            // Um som sem nota: a nota entra no cursor, na casa sugerida (a altura dele na corda do cursor).
            guard let fret = tabCaret?.fret else {
                tabMessage = "Soa \(Self.pitchName(current.suspect.pitch)) sem nota: digite a casa para escrever, ⌫ dispensa, → pula"
                return
            }
            tabEdit("fret", fret)
        } else {
            fitToSound()
        }
        reviewed += 1
        nextSuspect(1)
    }

    /// ⌫: a suspeita sai da fila (a nota fica como está); guardada por música, até "Mostrar de novo".
    func reviewDismiss() {
        guard let current = reviewCurrent else { return }
        dismissedSuspects.insert(suspectKey(current.suspect, track: scoreTrack))
        saveDismissed()
        reviewed += 1
        nextSuspect(1)
    }

    /// As dispensadas voltam à fila.
    func restoreDismissed() {
        dismissedSuspects = []
        saveDismissed()
    }

    /// Quantas suspeitas dispensadas há na pista de agora.
    var dismissedCount: Int {
        let prefix = "\(scoreTrack):"
        return dismissedSuspects.filter { $0.hasPrefix(prefix) }.count
    }
}

/// O painel do Revisar: onde está na fila, o que o som discorda, os cartões das leituras e as três decisões.
struct ReviewPanel: View {
    let model: SongModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = model.reviewCurrent {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("\(current.index + 1) de \(current.count)").font(.callout.weight(.semibold).monospacedDigit())
                        Text(current.suspect.kind.label).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                        Spacer()
                        if let bar = model.grid.bar(at: current.suspect.seconds + 0.001) {
                            Text("c. \(bar)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: Double(current.index + 1), total: Double(max(current.count, 1))).tint(.orange)
                    Text(current.suspect.note == nil
                         ? "Soa \(SongModel.pitchName(current.suspect.pitch)) sem nota escrita"
                         : SongModel.describe(current.suspect.reasons).prefix(1).uppercased()
                           + SongModel.describe(current.suspect.reasons).dropFirst())
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let summary = model.soundSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Button { model.reviewAccept() } label: {
                        HStack(spacing: 4) { Text("Aceitar o som"); KeyHint("⏎") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help("Escreve o que o som faz (o F: a altura, o bend e o vibrato; num som sem nota, a nota na casa "
                          + "sugerida) e vai à próxima")
                    Button { model.reviewDismiss() } label: {
                        HStack(spacing: 4) { Text("Está certa"); KeyHint("⌫") }.frame(maxWidth: .infinity)
                    }
                    .help("A escrita fica; a suspeita sai da fila desta música")
                }
                HStack(spacing: 6) {
                    Button { model.nextSuspect(-1) } label: { HStack(spacing: 4) { Text("Anterior"); KeyHint("←") }.frame(maxWidth: .infinity) }
                    Button { model.nextSuspect(1) } label: { HStack(spacing: 4) { Text("Pular"); KeyHint("→") }.frame(maxWidth: .infinity) }
                    Button { model.listenSelection() } label: { Image(systemName: "ear") }
                        .help("Ouvir a nota (O)")
                }
                ReadingCards(model: model)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
            } else {
                let count = model.suspects(track: model.scoreTrack).count
                Text(count == 0
                     ? (model.measuring ? "Medindo o som das notas…" : "Nenhuma suspeita desses tipos nesta pista.")
                     : "\(count) suspeita\(count == 1 ? "" : "s") na fila.")
                    .font(.callout)
                if count > 0 {
                    Button { model.nextSuspect(1) } label: {
                        HStack(spacing: 4) { Text("Ir à próxima"); KeyHint("→") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            if model.reviewed > 0 {
                Text("\(model.reviewed) revista\(model.reviewed == 1 ? "" : "s") nesta sessão").font(.caption).foregroundStyle(.secondary)
            }
            InspectorGroup("O que entra na fila", summary: "\(model.suspects(track: model.scoreTrack).count)", key: "review.kinds",
                           open: false) {
                SuspectFilter(model: model)
                if model.dismissedCount > 0 {
                    HStack {
                        Text("\(model.dismissedCount) dispensada\(model.dismissedCount == 1 ? "" : "s")").font(.caption)
                        Spacer()
                        Button("Mostrar de novo") { model.restoreDismissed() }
                    }
                }
            }
        }
    }
}
