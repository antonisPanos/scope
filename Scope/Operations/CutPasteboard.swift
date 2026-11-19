import AppKit

/// Cut belongs to the clipboard, rather than the selection in any one tab.
@MainActor
final class CutPasteboard: NSObject {
    static let shared = CutPasteboard(pasteboard: .general)
    static let didChange = Notification.Name("CutPasteboardDidChange")

    private let pasteboard: NSPasteboard
    private var changeCount: Int?
    private var paths: Set<String> = []
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.validate() }
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    var isCut: Bool {
        validate()
        return changeCount != nil
    }

    func contains(_ url: URL) -> Bool {
        validate()
        return paths.contains(url.standardizedFileURL.path)
    }

    /// An empty selection leaves the clipboard and any earlier cut alone.
    func write(_ urls: [URL], cut: Bool = false) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        invalidate()
        guard pasteboard.writeObjects(urls as [NSURL]), cut else { return }
        paths = Set(urls.map { $0.standardizedFileURL.path })
        changeCount = pasteboard.changeCount
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validate() }
        }
        timer = poll
        RunLoop.main.add(poll, forMode: .common)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Also used when paste consumes a cut, before its move is queued.
    func invalidate() {
        guard changeCount != nil else { return }
        changeCount = nil
        paths = []
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Only compares clipboard generations; never reads clipboard data or disk.
    func validate() {
        if let changeCount, changeCount != pasteboard.changeCount { invalidate() }
    }
}
