import Foundation
import ScopeEngine

// Scope's archive codecs run in this sandboxed process, with no user-file
// or network entitlements (Config/ScopeArchiveService.entitlements).
// Extraction receives one read-only archive descriptor and returns entries
// and bytes. Compression receives bounded entries/bytes and returns encoded
// bytes, with no source paths or output descriptor. The engine keeps all
// authorization, source traversal, output writes and final publication.

let acceptor = ArchiveServiceListener()
let listener = NSXPCListener.service()
listener.delegate = acceptor
listener.resume()
