import Foundation
import ScopeEngine

// Scope's archive service: reads archives for Extract in a process of its own.
// It runs in the App Sandbox with no file access at all (see
// Config/ScopeArchiveService.entitlements): the app opens each archive and
// sends only the open file, and gets back plain entries and data, which its
// engine checks and writes itself. A flaw in an archive parser can then
// reach nothing but the one archive it was given.

let acceptor = ArchiveServiceListener()
let listener = NSXPCListener.service()
listener.delegate = acceptor
listener.resume()
