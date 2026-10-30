import AppKit
import SwiftUI
import TrackLabCore
import WebKit

/// A partitura: `web/score.html` (alphaTab) numa WKWebView, no padrão do TablatureBridge do TabLab. A página não
/// tem áudio: o app empurra o relógio em play, pausa, seek, velocidade e a cada segundo; a página extrapola entre
/// os avisos, leva o tempo a tiques pelo mapa e rola a pauta sob o cursor parado a 40 % da largura.
/// Contrato em web/score.js.
@MainActor
final class ScoreBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "tracklab"
    static let clockPeriod: TimeInterval = 1

    struct PageTrack: Hashable {
        let index: Int
        let name: String
    }

    let webView: WKWebView
    private weak var engine: StemEngine?
    /// A partitura lida: as pistas, o início de cada compasso (e o fim do último) e as seções marcadas no Guitar Pro.
    var onLoaded: ((_ tracks: [PageTrack], _ barTicks: [Double], _ markers: [(tick: Double, name: String)],
                    _ notes: [[ScoreNote]]) -> Void)?
    var onRendered: ((_ ms: Int, _ height: Double?) -> Void)?
    var onError: ((String) -> Void)?
    /// Um aviso da edição para a barra (por que a nota não andou no tempo, por exemplo).
    var onNotice: ((String) -> Void)?
    /// Um loop marcado na página (arrastando de uma batida a outra, na faixa ou no modo página), em segundos.
    var onLoop: ((Double, Double) -> Void)?
    /// Um clique na faixa: os segundos e a fração da largura onde o cabeçote deve ficar.
    var onSeek: ((Double, Double) -> Void)?
    /// A edição da TAB: a nota escolhida (ou nil) e se há o que desfazer e refazer; o Guitar Pro editado para gravar;
    /// as notas novas (para o espectro).
    var onSelection: ((_ note: TabSelection?, _ canUndo: Bool, _ canRedo: Bool) -> Void)?
    /// O cursor de inserção (uma corda vazia escolhida na edição), ou nil.
    var onCaret: ((TabCaret?) -> Void)?
    /// Uma nota para ouvir: o clique (o som gravado) ou o botão direito (sintetizada); pista, tique, corda, altura e o
    /// trecho em tiques (`from`, `to`).
    var onHear: (([String: Any]) -> Void)?
    var onSave: ((Data) -> Void)?
    var onNotes: (([[ScoreNote]]) -> Void)?
    /// ⇧ + arrastar, no Ajuste: quanto a onda anda (segundos na escala da Fita), durante e ao soltar.
    var onShift: ((Double) -> Void)?
    var onShiftEnd: ((Double) -> Void)?
    private(set) var ready = false
    private var pending: [String: Any]?
    private var points: [[String: Any]] = []
    private var loopRange: ClosedRange<Double>?
    private var theme = "light"
    private var span = 10.0
    private var adjusting = false
    private var timer: Timer?
    private var observer: UUID?
    /// Um aviso de relógio por vez: rolando, o trackpad manda dezenas por segundo e eles fariam fila atrás do desenho
    /// da Fita (a TAB só chegava quando a rolagem parava). Os que chegam no meio viram um só, o mais novo.
    private var clockInFlight = false
    private var clockPending = false

    init(engine: StemEngine) {
        let config = WKWebViewConfiguration()
        webView = ScoreWebView(frame: .zero, configuration: config)
        self.engine = engine
        super.init()
        config.userContentController.add(self, name: Self.handlerName)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        observer = engine.observe { [weak self] in self?.pushClock() }
        let timer = Timer(timeInterval: Self.clockPeriod, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine?.isPlaying == true else { return }
                self.pushClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if let folder = Backend.webFolder {
            webView.loadFileURL(folder.appending(path: "score.html"), allowingReadAccessTo: folder)
        } else {
            Task { @MainActor [weak self] in self?.onError?("A página da partitura não está no app (web/score.html).") }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let observer { engine?.unobserve(observer) }
        observer = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    }

    // MARK: - Do app para a página

    /// O Guitar Pro (os bytes do arquivo), a pista, o mapa de tempo e o modo página; guardados até a página dizer
    /// `ready`.
    func load(gp: Data, track: Int, points: [TempoPoint], page: Bool = false) {
        self.points = Self.encode(points)
        pending = ["gp": gp.base64EncodedString(), "track": track, "points": self.points, "page": page]
        if ready { sendPending() }
    }

    /// A partitura em páginas (sistemas de cima para baixo, com o cursor na batida) ou na faixa horizontal da Fita.
    func showPage(_ page: Bool) {
        pending?["page"] = page
        call("window.tracklab.page(value)", ["value": page])
    }

    func showTrack(_ index: Int) {
        pending?["track"] = index
        call("window.tracklab.track(index)", ["index": index])
    }

    /// As outras pistas, embaixo da principal nos mesmos compassos, na ordem dada (vazia: só a principal).
    func showOthers(_ list: [Int]) {
        pending?["others"] = list
        call("window.tracklab.others(list)", ["list": list])
    }

    func setTempo(_ points: [TempoPoint]) {
        self.points = Self.encode(points)
        pending?["points"] = self.points
        call("window.tracklab.tempo(points)", ["points": self.points])
    }

    func setLoop(_ range: ClosedRange<Double>?) {
        loopRange = range
        sendLoop()
    }

    func setTheme(_ scheme: ColorScheme) {
        let name = scheme == .dark ? "dark" : "light"
        guard name != theme else { return }
        theme = name
        call("window.tracklab.theme(name)", ["name": name])
    }

    /// Os segundos que a Fita mostra na largura: a página desenha os compassos na mesma escala. Na pinça chegam
    /// dezenas por segundo: um aviso por vez, e os do meio viram o mais novo (como o relógio).
    func setSpan(_ seconds: Double) {
        guard seconds != span else { return }
        span = seconds
        guard ready else { return }
        if spanInFlight {
            spanPending = true
            return
        }
        spanInFlight = true
        webView.callAsyncJavaScript("window.tracklab.span(seconds); return null;", arguments: ["seconds": seconds],
                                    in: nil, in: .page) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spanInFlight = false
                if self.spanPending {
                    self.spanPending = false
                    let latest = self.span
                    self.span = .nan
                    self.setSpan(latest)
                }
            }
        }
    }

    private var spanInFlight = false
    private var spanPending = false

    /// A edição da TAB: um clique escolhe a nota.
    /// As barras de duração embaixo das notas na edição, e a grade delas (tiques: 240 é semicolcheia).
    func setDurations(_ on: Bool, grid: Int) {
        call("window.tracklab.durations(value)", ["value": on])
        call("window.tracklab.grid(ticks)", ["ticks": grid])
    }

    func setEditing(_ value: Bool) {
        call("window.tracklab.editing(value)", ["value": value])
    }

    /// Um comando da edição (`technique`, `fret`, `string`, `transpose`, `delete`, `nav`, `undo`, `redo`, `clear`).
    func edit(_ op: String, _ value: Any? = nil) {
        call("window.tracklab.edit(op, value)", ["op": op, "value": value ?? NSNull()])
    }

    /// A janela da Fita (`LoopView`): onde fica o cursor na largura e onde a pauta para sobre o loop.
    func setView(at: Double, pin: Double?) {
        guard at != cursorAt || pin != loopPin else { return }
        cursorAt = at
        loopPin = pin
        call("window.tracklab.view(at, pin)", ["at": at, "pin": pin ?? NSNull()])
    }

    private var cursorAt = 0.4
    private var loopPin: Double?

    /// No Ajuste a página aceita ⇧ + arrastar.
    func setAdjusting(_ value: Bool) {
        guard value != adjusting else { return }
        adjusting = value
        call("window.tracklab.adjusting(value)", ["value": value])
    }

    func pushClock() {
        guard ready, let engine else { return }
        if clockInFlight {
            clockPending = true
            return
        }
        clockInFlight = true
        let arguments: [String: Any] = ["seconds": engine.currentTime, "playing": engine.isPlaying,
                                        "rate": Double(engine.rate), "delay": engine.startDelay]
        webView.callAsyncJavaScript("window.tracklab.clock(seconds, playing, rate, delay); return null;",
                                    arguments: arguments, in: nil, in: .page) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clockInFlight = false
                if self.clockPending {
                    self.clockPending = false
                    self.pushClock()
                }
            }
        }
    }

    private func sendPending() {
        call("window.tracklab.theme(name)", ["name": theme])
        call("window.tracklab.span(seconds)", ["seconds": span])
        call("window.tracklab.adjusting(value)", ["value": adjusting])
        call("window.tracklab.view(at, pin)", ["at": cursorAt, "pin": loopPin ?? NSNull()])
        if let pending { call("window.tracklab.load(payload)", ["payload": pending]) }
        sendLoop()
        pushClock()
    }

    private func sendLoop() {
        if let loopRange {
            call("window.tracklab.loop(a, b)", ["a": loopRange.lowerBound, "b": loopRange.upperBound])
        } else {
            call("window.tracklab.loop(null, null)", [:])
        }
    }

    private static func encode(_ points: [TempoPoint]) -> [[String: Any]] {
        points.map { ["tick": $0.tick, "seconds": $0.seconds, "kind": $0.kind] }
    }

    /// Os argumentos vão como valores do JavaScript, sem montar texto com eles; nada volta da página.
    private func call(_ body: String, _ arguments: [String: Any]) {
        guard ready else { return }
        let webView = webView
        Task { @MainActor [weak self] in
            do {
                _ = try await webView.callAsyncJavaScript(body + "; return null;", arguments: arguments, contentWorld: .page)
            } catch {
                self?.onError?("A página da partitura falhou: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Da página para o app

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let body = message.body as? [String: Any] ?? [:]
            switch body["type"] as? String {
            case "ready":
                ready = true
                sendPending()
            case "loaded":
                let list = (body["tracks"] as? [[String: Any]] ?? []).compactMap { item -> PageTrack? in
                    guard let index = (item["index"] as? NSNumber)?.intValue else { return nil }
                    return PageTrack(index: index, name: item["name"] as? String ?? "Faixa \(index + 1)")
                }
                let ticks = (body["barTicks"] as? [NSNumber] ?? []).map(\.doubleValue)
                let markers = (body["sections"] as? [[String: Any]] ?? []).compactMap { item -> (tick: Double, name: String)? in
                    guard let tick = (item["tick"] as? NSNumber)?.doubleValue, let name = item["name"] as? String,
                          !name.isEmpty else { return nil }
                    return (tick, name)
                }
                let notes = (body["notes"] as? [[[NSNumber]]] ?? []).map { track in
                    ScoreNote.list(track.map { $0.map(\.doubleValue) })
                }
                onLoaded?(list, ticks, markers, notes)
            case "rendered":
                onRendered?((body["ms"] as? NSNumber)?.intValue ?? 0, (body["height"] as? NSNumber)?.doubleValue)
            case "selection":
                let note = (body["note"] as? [String: Any]).flatMap(TabSelection.init(page:))
                onSelection?(note, body["canUndo"] as? Bool ?? false, body["canRedo"] as? Bool ?? false)
                onCaret?(TabCaret(page: body["caret"] as? [String: Any]))
            case "hear":
                onHear?(body)
            case "save":
                if let text = body["gp"] as? String, let data = Data(base64Encoded: text) { onSave?(data) }
            case "notes":
                onNotes?((body["notes"] as? [[[NSNumber]]] ?? []).map { ScoreNote.list($0.map { $0.map(\.doubleValue) }) })
            case "shift":
                onShift?((body["seconds"] as? NSNumber)?.doubleValue ?? 0)
            case "shiftEnd":
                if let seconds = (body["seconds"] as? NSNumber)?.doubleValue { onShiftEnd?(seconds) }
            case "seek":
                // Um clique na faixa: o cabeçote vai para onde o mouse estava (`at`, fração da largura).
                guard let seconds = (body["seconds"] as? NSNumber)?.doubleValue else { break }
                if let at = (body["at"] as? NSNumber)?.doubleValue, let onSeek {
                    onSeek(seconds, at)
                } else {
                    engine?.seek(to: seconds)
                }
            case "loop":
                if let start = (body["start"] as? NSNumber)?.doubleValue, let end = (body["end"] as? NSNumber)?.doubleValue {
                    onLoop?(start, end)
                }
            case "notice":
                if let text = body["text"] as? String { onNotice?(text) }
            case "error":
                onError?(body["message"] as? String ?? "A página da partitura avisou um erro.")
            default:
                break
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let text = error.localizedDescription
        MainActor.assumeIsolated { onError?("A página da partitura não carregou: \(text)") }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            ready = false
            onError?("A página da partitura parou; abra a música de novo.")
        }
    }
}

/// A página da partitura sem o foco do teclado: com ele, a WKWebView engolia o espaço, as setas e as letras, e os
/// atalhos do transporte paravam depois de um clique na TAB (as teclas da edição vêm pelo monitor do app). Um clique
/// nela também tira o foco de um campo de texto (a busca), como um clique na Fita.
final class ScoreWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is NSText { window?.makeFirstResponder(nil) }
        super.mouseDown(with: event)
    }
}

struct ScoreView: View {
    let bridge: ScoreBridge
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScoreWebHost(bridge: bridge, colorScheme: colorScheme)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ScoreWebHost: NSViewRepresentable {
    let bridge: ScoreBridge
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> WKWebView {
        bridge.setTheme(colorScheme)
        return bridge.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        bridge.setTheme(colorScheme)
    }
}
