import Foundation
import SafariServices
import os.log

private let safariExtLogger = Logger(subsystem: "com.charkle.app.SafariExtension", category: "Handler")

@objc(CharkleSafariExtensionHandler)
public final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    public func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]
        safariExtLogger.debug("Received Safari Web Extension native message")

        let response = NSExtensionItem()
        response.userInfo = [
            SFExtensionMessageKey: [
                "ok": true,
                "app": "charkle-macos",
                "echo": message ?? NSNull()
            ]
        ]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
