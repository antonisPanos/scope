// Sends a request to a running Pandora Dev build (see Pandora/App/DevHooks.swift).
// Usage: swift scripts/devhook.swift command:viewList [go:/Volumes/PandoraTest/names ...]
// Each argument is sent in order, half a second apart.
import Foundation

for request in CommandLine.arguments.dropFirst() {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.antonispanos.pandora.dev.hook"), object: request, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.5)
}
