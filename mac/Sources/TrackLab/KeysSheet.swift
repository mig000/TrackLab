import SwiftUI

/// A folha de teclas (⌘/): o que cada tecla faz em cada modo, no lugar das dicas em cada botão da coluna.
struct KeysSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let study: [(String, String)] = [
        ("Espaço", "toca e pausa"), ("← →", "5 segundos"), ("Home", "o começo (do loop)"), ("L", "loop no compasso"),
        ("K", "metrônomo"), ("⏎", "Limpo! no trecho ativo"), ("X", "áudio ⇄ TAB sintetizada"), ("B", "A/B das faixas"),
        ("Z", "a Lente em volta da nota que toca"), ("Tab ⇧Tab", "a suspeita seguinte / anterior"),
        ("⌘+ ⌘−", "zoom (pinça também)"), ("⌥⌘1 ⌥⌘2", "Onda, Lente"), ("⌥⌘I", "o inspetor"), ("⌘E ⌘J", "Editar, Ajustar"),
        ("⌥⌘R", "reconhecer um trecho no espectro"), ("⌥ + arrastar na Lente", "o mesmo, pelo retângulo"),
    ]
    static let edit: [(String, String)] = [
        ("0–9", "a casa (dois dígitos em 0,6 s)"), ("↑ ↓", "outra corda, mesma altura"), ("⌥↑ ⌥↓", "meio tom"),
        ("← →", "nota anterior / seguinte"), ("⇧← ⇧→", "escolhe mais uma"), ("⌥← ⌥→", "um passo da grade no tempo"),
        ("⌫", "apaga"), ("⇧⌫", "vira pausa"), ("− =", "a figura da metade / do dobro"), (". T", "pontuada, tercina"),
        ("/", "divide em duas ligadas"), ("D", "barras de duração"), ("L H S", "ligada, ligado, slide"),
        ("B ⇧B", "bend: a altura, o tipo"), ("V M X N", "vibrato, palm mute, nota morta, harmônico"),
        ("G A R P", "fantasma, acento, let ring, palhetada"), ("F ⇧F", "encaixa no som, corrige a pista"),
        ("⌥1–⌥4", "a leitura do cartão"), ("O", "ouve as notas escolhidas"), ("⌘C ⌘X ⌘V", "copia, recorta, cola"),
        ("Esc", "solta a nota; de novo, sai da edição"), ("botão direito", "o menu da nota ou do compasso"),
    ]
    static let record: [(String, String)] = [
        ("⌘R", "o modo Gravar"), ("R", "grava e para (com loop, um take por volta)"), ("B", "compara com o take anterior"),
        ("clique num take", "ele passa a soar"), ("clique numa pista", "ela fica armada"),
        ("botão direito no take", "ouvir, renomear, levar, timbre, exportar, apagar"),
    ]
    static let adjust: [(String, String)] = [
        ("arrastar uma batida", "ela vai até onde soa (vira âncora)"), ("duplo clique", "prende ou solta a batida"),
        ("U", "o 1 é aqui, no toque"), ("T", "bater junto"), ("A ⇧A", "o compasso / a música pelo som"),
        ("⇧ + arrastar na TAB", "a onda desliza sob a TAB parada"), ("C", "conferido"), ("⌘Z ⇧⌘Z", "desfaz, refaz"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Teclas").font(.title3.weight(.semibold))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 24) {
                column("Estudar", Self.study)
                column("Editar", Self.edit)
                VStack(alignment: .leading, spacing: 18) {
                    column("Ajustar", Self.adjust)
                    column("Gravar", Self.record)
                }
            }
        }
        .padding(20)
        .frame(width: 900)
    }

    private func column(_ title: String, _ keys: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(keys, id: \.0) { key, what in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key).font(.caption.monospaced()).frame(width: 150, alignment: .trailing)
                    Text(what).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
