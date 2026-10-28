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
    var onLoaded: ((_ tracks: [PageTrack], _ barTicks: [Double]) -> Void)?
    var onRendered: ((_ ms: Int, _ height: Double?) -> Void)?
    var onError: ((String) -> Void)?
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

    init(engine: StemEngine) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
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

    /// O Guitar Pro (os bytes do arquivo), a pista e o mapa de tempo; guardados até a página dizer `ready`.
    func load(gp: Data, track: Int, points: [TempoPoint]) {
        self.points = Self.encode(points)
        pending = ["gp": gp.base64EncodedString(), "track": track, "points": self.points]
        if ready { sendPending() }
    }

    func showTrack(_ index: Int) {
        pending?["track"] = index
        call("window.tracklab.track(index)", ["index": index])
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

    /// Os segundos que a Fita mostra na largura: a página desenha os compassos na mesma escala.
    func setSpan(_ seconds: Double) {
        guard seconds != span else { return }
        span = seconds
        call("window.tracklab.span(seconds)", ["seconds": seconds])
    }

    /// No Ajuste a página aceita ⇧ + arrastar.
    func setAdjusting(_ value: Bool) {
        guard value != adjusting else { return }
        adjusting = value
        call("window.tracklab.adjusting(value)", ["value": value])
    }

    func pushClock() {
        guard ready, let engine else { return }
        call("window.tracklab.clock(seconds, playing, rate, delay)",
             ["seconds": engine.currentTime, "playing": engine.isPlaying, "rate": Double(engine.rate),
              "delay": engine.startDelay])
    }

    private func sendPending() {
        call("window.tracklab.theme(name)", ["name": theme])
        call("window.tracklab.span(seconds)", ["seconds": span])
        call("window.tracklab.adjusting(value)", ["value": adjusting])
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
                onLoaded?(list, ticks)
            case "rendered":
                onRendered?((body["ms"] as? NSNumber)?.intValue ?? 0, (body["height"] as? NSNumber)?.doubleValue)
            case "shift":
                onShift?((body["seconds"] as? NSNumber)?.doubleValue ?? 0)
            case "shiftEnd":
                if let seconds = (body["seconds"] as? NSNumber)?.doubleValue { onShiftEnd?(seconds) }
            case "seek":
                if let seconds = (body["seconds"] as? NSNumber)?.doubleValue { engine?.seek(to: seconds) }
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

struct ScoreView: View {
    let bridge: ScoreBridge
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScoreWebView(bridge: bridge, colorScheme: colorScheme)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ScoreWebView: NSViewRepresentable {
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
