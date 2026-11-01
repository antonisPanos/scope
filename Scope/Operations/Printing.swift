import AppKit
import PDFKit
import ScopeEngine
import UniformTypeIdentifiers

/// Print (Cmd+P or the right-click menu) for PDFs, images and text documents.
/// Scope prints them itself through the standard print panel, one file after
/// another, instead of asking each file's app to do it. The file is read
/// through the engine off the main thread; only the drawing happens here.
extension BrowserWindowController {
    /// Whether every selected item is a file Scope knows how to print.
    var canPrintSelection: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy { PrintableKind($0) != nil }
    }

    func printSelection() {
        let files = selectedItems.filter { PrintableKind($0) != nil }
        guard !files.isEmpty else { return }
        let engine = model.engine
        let window = window
        Task {
            for file in files {
                guard let kind = PrintableKind(file) else { continue }
                do {
                    let data = try await engine.contents(of: file.url)
                    guard let operation = kind.printOperation(for: data, name: file.name) else {
                        throw PrintError.unreadable(file.name)
                    }
                    guard await run(operation, in: window) else { return }
                } catch {
                    let alert = NSAlert(error: error)
                    if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
        }
    }

    /// Shows the print panel as a sheet; false when the user cancels it.
    private func run(_ operation: NSPrintOperation, in window: NSWindow?) async -> Bool {
        guard let window else { return operation.run() }
        return await withCheckedContinuation { continuation in
            let delegate = PrintCompletion { continuation.resume(returning: $0) }
            operation.runModal(
                for: window, delegate: delegate,
                didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }
}

private enum PrintError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Scope can't print “\(name)”."
        }
    }
}

/// Receives the print sheet's result and keeps itself alive until then.
private final class PrintCompletion: NSObject {
    private var done: ((Bool) -> Void)?
    private var keepAlive: PrintCompletion?

    init(_ done: @escaping (Bool) -> Void) {
        self.done = done
        super.init()
        keepAlive = self
    }

    @objc func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        done?(success)
        done = nil
        keepAlive = nil
    }
}

enum PrintableKind {
    case pdf, image, text

    init?(_ item: FileItem) {
        guard !item.isDirectory, !item.isPackage,
            let type = UTType(filenameExtension: item.url.pathExtension)
        else { return nil }
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .plainText) || type.conforms(to: .rtf) || type.conforms(to: .html)
            || Self.documentTypes.contains(where: type.conforms(to:))
        {
            self = .text
        } else {
            return nil
        }
    }

    /// Word processing formats that NSAttributedString reads.
    private static let documentTypes: [UTType] = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text", "com.apple.webarchive",
    ].compactMap { UTType($0) }

    @MainActor
    func printOperation(for data: Data, name: String) -> NSPrintOperation? {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        let operation: NSPrintOperation?
        switch self {
        case .pdf:
            operation = PDFDocument(data: data)?.printOperation(
                for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        case .image:
            guard let image = NSImage(data: data) else { return nil }
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            let printable = info.imageablePageBounds.size
            let scale = min(1, printable.width / image.size.width, printable.height / image.size.height)
            let view = NSImageView(
                frame: NSRect(
                    origin: .zero, size: NSSize(width: image.size.width * scale, height: image.size.height * scale)))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            operation = NSPrintOperation(view: view, printInfo: info)
        case .text:
            guard let text = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) else {
                return nil
            }
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isVerticallyCentered = false
            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            view.textStorage?.setAttributedString(text)
            view.isVerticallyResizable = true
            view.sizeToFit()
            operation = NSPrintOperation(view: view, printInfo: info)
        }
        operation?.jobTitle = name
        operation?.showsPrintPanel = true
        operation?.showsProgressPanel = true
        return operation
    }
}
