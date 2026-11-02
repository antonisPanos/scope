import AppKit

/// The toolbar search field: searches the folder on screen, with a pause in
/// typing before each crawl.
extension BrowserWindowController: NSSearchFieldDelegate {
    /// Cmd+F: put the cursor in the search field.
    func beginSearch() {
        searchToolbarItem?.beginSearchInteraction()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchToolbarItem?.searchField else {
            return
        }
        // Wait for a pause in typing before crawling.
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.content.search.text = field.stringValue
            self.runSearch()
        }
    }

    @objc func searchFieldChanged(_ sender: NSSearchField) {
        searchDebounce?.cancel()
        content.search.text = sender.stringValue
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchToolbarItem?.searchField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endSearch()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            // Return or Down moves into the results.
            focusFileList()
            return true
        default:
            return false
        }
    }

    /// Searches the folder on screen (or the folder the current search is in)
    /// with the field's text and the filter bar's settings.
    func runSearch() {
        let query = content.search.query
        guard let root = model.location.searchRoot else { return }
        if query.isEmpty && !model.location.isSearch { return }
        if query.text.trimmingCharacters(in: .whitespaces).isEmpty && query.isEmpty {
            endSearch()
            return
        }
        let destination = Location.search(query, in: root)
        if model.location.isSearch {
            model.replace(with: destination)
        } else {
            model.navigate(to: destination)
        }
    }

    /// Back to the folder that was searched.
    func endSearch() {
        searchDebounce?.cancel()
        searchToolbarItem?.searchField.stringValue = ""
        content.search.reset()
        guard case .search(_, let root) = model.location else { return }
        model.replace(with: .folder(root))
        focusFileList()
    }

    /// Escape stops a running search, then ends it.
    override func cancelOperation(_ sender: Any?) {
        if model.isSearching {
            model.stopSearch()
        } else if model.location.isSearch {
            endSearch()
        }
    }
}
