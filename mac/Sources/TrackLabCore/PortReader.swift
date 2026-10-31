import Foundation

/// Lê `TRACKLAB_PORT=<n>` do stdout do motor, que chega em pedaços numa thread qualquer. Só uma linha inteira (até o
/// fim de linha) vale: um pedaço que parasse no meio do número ("TRACKLAB_PORT=35" e depois "121") daria a porta
/// errada, e o app esperaria 90 s por um motor que estava no ar.
public final class PortReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var found: Int?

    public init() {}

    public var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return found
    }

    public func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard found == nil else { return }
        buffer += String(decoding: data, as: UTF8.self)
        while let end = buffer.firstIndex(of: "\n") {
            let line = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...end)
            if line.hasPrefix("TRACKLAB_PORT="), let port = Int(line.dropFirst("TRACKLAB_PORT=".count)),
               (1...65_535).contains(port) {
                found = port
                return
            }
        }
        if buffer.count > 10_000 { buffer = String(buffer.suffix(1_000)) }
    }
}
