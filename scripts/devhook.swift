// Sends a request to a running Scope Dev build (see Scope/App/DevHooks.swift).
// Usage: swift scripts/devhook.swift command:viewList [go:~/ScopeScratch ...]
// Each argument is sent in order, half a second apart.
import Foundation

for request in CommandLine.arguments.dropFirst() {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.antonispanos.scope.dev.hook"), object: request, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.5)
}
