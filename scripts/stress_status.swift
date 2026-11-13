// Reads a machine-readable snapshot from a running Scope Dev stress session.
import Foundation

let requestID = UUID().uuidString
let targetRunID = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : nil
let reply = Notification.Name("com.antonispanos.scope.dev.stress.reply")
let request = Notification.Name("com.antonispanos.scope.dev.hook")
var response: String?
let observer = DistributedNotificationCenter.default().addObserver(
    forName: reply, object: requestID, queue: nil
) { notification in
    response = notification.userInfo?["json"] as? String
}
defer { DistributedNotificationCenter.default().removeObserver(observer) }
DistributedNotificationCenter.default().postNotificationName(
    request, object: "stress-status:" + requestID,
    userInfo: targetRunID.map { ["stressRunID": $0] }, deliverImmediately: true)
let deadline = Date().addingTimeInterval(5)
while response == nil && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard let response else {
    fputs("No Scope Dev stress reply within five seconds\n", stderr)
    exit(1)
}
print(response)
