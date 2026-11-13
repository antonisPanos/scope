// Sends a request to a running Scope Dev build (see Scope/App/DevHooks.swift).
// Usage: swift scripts/devhook.swift command:viewList [go:~/ScopeScratch ...]
// Each argument is sent in order, half a second apart.
import Foundation

var requests = Array(CommandLine.arguments.dropFirst())
var runID: String?
if requests.first == "--stress-run-id", requests.count >= 3 {
    runID = requests[1]
    requests.removeFirst(2)
}
for request in requests {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.antonispanos.scope.dev.hook"), object: request,
        userInfo: runID.map { ["stressRunID": $0] }, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.5)
}
