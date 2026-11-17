import Foundation
import UIKit
import UserNotifications
import WebKit
import SwiftUI
import EasyTipView

@available(iOS 15.2, *)
public class PushApp: NSObject {
    public static let shared = PushApp()

    private var serverUrl : String = ""
    var userId: String?
    private var guestId: String?
    internal var tenant: String = ""
    private var channelId: String = ""
    private var socketManager: WebSocketManager?
    private var inAppDisplay: InAppDisplay?
    private var currentContext: UIViewController?
    internal var sandbox: Bool = false
    
    let slackWebhookURL = URL(string: "https://hooks.slack.com/services/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")!
    

    private override init() {}

    public func initialize(identifier: String, sandbox: Bool = false) {
        self.sandbox = sandbox
        guard let context = self.topViewController() else {
                self.slackPrint("⚠️ Unable to find top view controller")
                return
            }
        self.currentContext = context
        let parts = identifier.split(separator: "$")
        if parts.count == 2 {
            self.tenant = String(parts[0])
            self.channelId = String(parts[1])
            self.slackPrint(self.tenant)
            self.slackPrint(self.channelId)
        } else {
            self.slackPrint("Invalid identifier format")
        }
        
        if sandbox {
            // sandbox: tenant.mehery.com
            self.serverUrl = "https://\(self.tenant).pushapp.com"
        } else {
            // production: tenant.mehery.com/pushapp
            self.serverUrl = "https://\(self.tenant).pushapp.co.in"
        }
        self.slackPrint("Server URL set to: \(self.serverUrl)")

        self.inAppDisplay = InAppDisplay(context: context)

        if let savedUserId = UserDefaults.standard.string(forKey: "pushapp_user_id") {
            self.userId = savedUserId
            self.sendEvent(eventName: "app_open", eventData: ["compare": channelId])
            self.connectSocket()
        } else {
            registerDeviceToken()
        }
        
        registerNotificationCategories()
    }
    
    func slackPrint(_ message: String) {
        // Print to console
        print(message)
        
        // Send to Slack
        var request = URLRequest(url: slackWebhookURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["text": message]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("⚠️ Failed to encode Slack message: \(error)")
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("⚠️ Slack send error: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("⚠️ Slack returned status: \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
    }

    func getDeviceHeaders() -> [String: String] {
        var headers: [String: String] = [:]

        // Device ID (non-persistent, per vendor)
        let deviceId = getPersistentDeviceId()
        headers["X-Device-ID"] = deviceId


        // Locale
        let locale = Locale.current.identifier

        // Screen resolution & orientation
        let screen = UIScreen.main
        let screenWidth = Int(screen.bounds.width * screen.scale)
        let screenHeight = Int(screen.bounds.height * screen.scale)
        let orientation = UIDevice.current.orientation.isLandscape ? "Landscape" : "Portrait"

        // Timezone
        let timezone = TimeZone.current.identifier

        // System info
        let device = UIDevice.current
        let osName = device.systemName
        let osVersion = device.systemVersion
        let deviceModel = getDeviceModel() // detailed like "iPhone14,3"
        let manufacturer = "Apple"

        // App info
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? ""
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""

        // Fill headers
        headers["X-Device-ID"] = deviceId
        headers["X-Screen-Resolution"] = "\(screenWidth)x\(screenHeight)"
        headers["X-Device-Orientation"] = orientation
        headers["X-Locale"] = locale
        headers["X-Timezone"] = timezone
        headers["X-OS-Name"] = osName
        headers["X-OS-Version"] = osVersion
        headers["X-Device-Model"] = deviceModel
        headers["X-Manufacturer"] = manufacturer
        headers["X-Bundle-ID"] = bundleId
        headers["X-App-Version"] = appVersion
        headers["X-Build-Number"] = buildNumber

        return headers
    }

    // Helper: detailed device model (e.g. "iPhone14,3")
    func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        return modelCode
    }


    private func registerDeviceToken() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    public func handleDeviceToken(_ deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        self.slackPrint("APNs Token: \(tokenString)")

        let defaults = UserDefaults.standard
        let lastToken = defaults.string(forKey: "apns_token")

        if lastToken != tokenString {
            self.slackPrint("📡 New APNs token detected, sending to server...")
            sendTokenToServer(platform: "ios", token: tokenString)
        } else {
            self.slackPrint("✅ Token unchanged, not sending to server")
        }
    }

    private func sendTokenToServer(platform: String, token: String) {
        guard let deviceId = getPersistentDeviceId() as String? else {
            self.slackPrint("❌ Failed to get deviceId")
            return
        }

        let urlString = "\(serverUrl)/pushapp/api/register"
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let payload: [String: Any] = [
            "platform": platform,
            "token": token,
            "device_id": deviceId,
            "channel_id": channelId
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.slackPrint("📤 Sending Token Request: \(urlString)")
            self.slackPrint("📦 Payload: \(jsonString)")
            request.httpBody = jsonData
        } else {
            self.slackPrint("❌ Failed to serialize payload")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ Token send failed: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 HTTP Status: \(httpResponse.statusCode)")
                self.slackPrint("🌐 Headers: \(httpResponse.allHeaderFields)")
            }

            guard let data = data else {
                self.slackPrint("❌ No response data received")
                return
            }

            if let rawString = String(data: data, encoding: .utf8) {
                self.slackPrint("📥 Raw Response: \(rawString)")
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
                self.slackPrint("✅ Parsed JSON: \(json)")

                if let responseDict = json as? [String: Any],
                   let device = responseDict["device"] as? [String: Any],
                   let guest = device["user_id"] as? String {
                    let defaults = UserDefaults.standard
                    defaults.set(token, forKey: "apns_token")
                    self.guestId = guest
                    self.slackPrint("🎉 Guest ID set: \(guest)")
                } else {
                    self.slackPrint("⚠️ JSON structure did not match expected format")
                }
            } catch {
                self.slackPrint("❌ Token send JSON parse error: \(error)")
            }
        }.resume()
    }


    public func login(userId: String) {
        self.slackPrint("🔑 Starting login for user: \(userId)")

        self.userId = userId
        UserDefaults.standard.setValue(userId, forKey: "pushapp_user_id")
        self.slackPrint("💾 Saved userId in UserDefaults")

        connectSocket()
        self.slackPrint("🔌 Socket connection initiated")

        guard let deviceId = getPersistentDeviceId() as String? else {
            self.slackPrint("❌ Failed to get deviceId")
            return
        }

        let urlString = "\(serverUrl)/pushapp/api/register/user"
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        self.slackPrint("📩 Attached device headers: \(deviceHeaders)")

        let payload: [String: Any] = [
            "user_id": userId,
            "device_id": deviceId,
            "channel_id": channelId
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.slackPrint("📤 Sending Login Request: \(urlString)")
            self.slackPrint("📦 Payload: \(jsonString)")
            request.httpBody = jsonData
        } else {
            self.slackPrint("❌ Failed to serialize login payload")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ Login request failed: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 Login Response Status: \(httpResponse.statusCode)")
                self.slackPrint("🌐 Headers: \(httpResponse.allHeaderFields)")
            }

            guard let data = data else {
                self.slackPrint("❌ No response data received for login")
                return
            }

            if let rawString = String(data: data, encoding: .utf8) {
                self.slackPrint("📥 Raw Login Response: \(rawString)")
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
                self.slackPrint("✅ Parsed Login JSON: \(json)")
            } catch {
                self.slackPrint("❌ Login JSON parse error: \(error)")
            }
        }.resume()
    }


    private func connectSocket() {
        guard let id = userId else { return }
        DispatchQueue.main.async {
            self.socketManager = WebSocketManager(userId: id, onMessage: { data in
                self.handleNotification(data)
            })
            self.socketManager?.connect()
        }
    }
    
    public static func showTooltip(text: String, for view: UIView, in container: UIView? = nil) {
        var preferences = EasyTipView.Preferences()
        preferences.drawing.font = UIFont.systemFont(ofSize: 14)
        preferences.drawing.foregroundColor = .white
        preferences.drawing.backgroundColor = .black
        preferences.drawing.arrowPosition = .top

        let tooltip = EasyTipView(text: text, preferences: preferences, delegate: nil)
        tooltip.show(forView: view, withinSuperview: container)
    }

    public func sendEvent(eventName: String, eventData: [String: Any]) {
        guard let userIdToUse = userId ?? guestId else {
            self.slackPrint("❌ No userId or guestId available. Event not sent.")
            return
        }

        self.slackPrint("📢 Event Triggered: \(eventName)")
        self.slackPrint("🗂 Event Data: \(eventData)")

        let urlString = "\(serverUrl)/pushapp/api/v1/event"
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL for sending event: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        self.slackPrint("📩 Device headers attached: \(deviceHeaders)")

        let payload: [String: Any] = [
            "user_id": userIdToUse,
            "channel_id": channelId,
            "event_name": eventName,
            "event_data": eventData
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.slackPrint("📤 Sending Event Request to: \(urlString)")
            self.slackPrint("📦 Event Payload: \(jsonString)")
            request.httpBody = jsonData
        } else {
            self.slackPrint("❌ Failed to serialize event payload")
            return
        }

        // Poll in-app notifications after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let savedUserId = UserDefaults.standard.string(forKey: "pushapp_user_id") {
                self.slackPrint("⏱ Polling in-app notifications for userId: \(savedUserId)")
                self.pollForInApp(userId: savedUserId)
            } else {
                self.slackPrint("❌ No saved userId for in-app polling")
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ Event request failed: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 Event Response Status: \(httpResponse.statusCode)")
                self.slackPrint("🌐 Response Headers: \(httpResponse.allHeaderFields)")
            }

            guard let data = data else {
                self.slackPrint("❌ No data received for event request")
                return
            }

            if let rawString = String(data: data, encoding: .utf8) {
                self.slackPrint("📥 Raw Event Response: \(rawString)")
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
                self.slackPrint("✅ Parsed Event JSON: \(json)")
            } catch {
                self.slackPrint("❌ Event JSON parse error: \(error)")
            }
        }.resume()
    }


    private func handleNotification(_ data: [String: Any]) {
//        if let messageType = data["message_type"] as? String, messageType == "rule_triggered",
//           let ruleId = data["rule_id"] as? String {
////            pollForInApp(ruleId: ruleId)
//        } else {
//            inAppDisplay?.showInApp(from: data)
//        }
    }

    public func pollForInApp(userId: String) {
        guard let deviceId = getPersistentDeviceId() as String? else {
            self.slackPrint("❌ Failed to get deviceId")
            return
        }
        
        let urlString = "\(serverUrl)/pushapp/api/v1/notification/in-app/poll"
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL for in-app polling: \(urlString)")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        self.slackPrint("📩 Device headers attached for in-app poll: \(deviceHeaders)")
        
        let bodyPayload = ["contact_id": userId + "_" + deviceId]
        if let jsonData = try? JSONSerialization.data(withJSONObject: bodyPayload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.slackPrint("📤 Sending in-app poll request to: \(urlString)")
            self.slackPrint("📦 In-App Poll Payload: \(jsonString)")
            request.httpBody = jsonData
        } else {
            self.slackPrint("❌ Failed to serialize in-app poll payload")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ In-app poll request failed: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 In-app poll Response Status: \(httpResponse.statusCode)")
                self.slackPrint("🌐 Response Headers: \(httpResponse.allHeaderFields)")
            }
            
            guard let data = data else {
                self.slackPrint("❌ No data received for in-app poll request")
                return
            }
            
            if let rawString = String(data: data, encoding: .utf8) {
                self.slackPrint("📥 Raw In-App Poll Response: \(rawString)")
            }
            
            do {
                if let responseDict = try JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] {
                    let success = responseDict["success"] as? Bool ?? false
                    self.slackPrint("✅ Poll success: \(success)")
                    
                    if success, let notifications = responseDict["results"] as? [[String: Any]] {
                        self.slackPrint("📬 Notifications received: \(notifications.count)")
                        for (index, notif) in notifications.enumerated() {
                            self.slackPrint("🔹 Notification \(index + 1): \(notif)")
                        }
                        if notifications.count > 0{
                            DispatchQueue.main.async {
                                self.inAppDisplay?.showInApp(from: notifications)
                            }
                        }
                    } else {
                        self.slackPrint("⚠️ No notifications available or success=false")
                    }
                } else {
                    self.slackPrint("❌ In-app poll response is not a valid dictionary")
                }
            } catch {
                self.slackPrint("❌ Error parsing in-app poll response: \(error)")
            }
        }.resume()
    }
    
    func ackInApp(contactId: String, messageId: String, completion: @escaping (Bool) -> Void) {
        let urlString = "\(serverUrl)/pushapp/api/v1/notification/in-app/ack"
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL for in-app ack: \(urlString)")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let bodyPayload = [
            "contact_id": contactId,
            "messageId": messageId
        ]
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: bodyPayload, options: [])
            request.httpBody = jsonData
        } catch {
            self.slackPrint("❌ Failed to serialize ack payload: \(error)")
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ In-app ack request failed: \(error.localizedDescription)")
                completion(false)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 In-app ack Response Status: \(httpResponse.statusCode)")
            }

            completion(true)
        }.resume()
    }
    
    
    func trackInAppEvent(messageId: String,
                         event: String,
                         filterId: String? = nil,
                         ctaId: String? = nil,
                         completion: @escaping (Bool) -> Void) {
        
        let urlString = "\(serverUrl)/pushapp/api/v1/notification/in-app/track"
        print(urlString)
        guard let url = URL(string: urlString) else {
            self.slackPrint("❌ Invalid URL for in-app track: \(urlString)")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach device headers
        let deviceHeaders = getDeviceHeaders()
        for (key, value) in deviceHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Build payload
        var bodyPayload: [String: Any] = [
            "messageId": messageId,
            "event": event
        ]
        if let filterId = filterId {
            bodyPayload["filterId"] = filterId
        }
        if let ctaId = ctaId {
            bodyPayload["data"] = ["ctaId": ctaId]
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: bodyPayload, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("✅ Payload for in app track:\n\(jsonString)")
        } else {
            print("❌ Failed to serialize payload to JSON")
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: bodyPayload, options: [])
            request.httpBody = jsonData
        } catch {
            self.slackPrint("❌ Failed to serialize track payload: \(error)")
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.slackPrint("❌ In-app track request failed: \(error.localizedDescription)\(self.serverUrl)/api/v1/notification/in-app/track")
                completion(false)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.slackPrint("🌐 In-app track Response Status: \(httpResponse.statusCode) for ")
            }

            completion(true)
        }.resume()
    }






    
    private func registerNotificationCategories() {
        let categoryMap: [(String, [(title: String, id: String)])] = [
            ("CONFIRMATION_CATEGORY", [("Yes", "PUSHAPP_YES"), ("No", "PUSHAPP_NO")]),
            ("RESPONSE_CATEGORY", [("Accept", "PUSHAPP_ACCEPT"), ("Reject", "PUSHAPP_REJECT")]),
            ("SUBSCRIPTION_CATEGORY", [("Subscribe", "PUSHAPP_SUB"), ("Unsubscribe", "PUSHAPP_UNSUB")]),
            ("TRANSACTION_CATEGORY", [("Buy", "PUSHAPP_BUY"), ("Sell", "PUSHAPP_SELL")]),
            ("CONTENT_CATEGORY", [("View", "PUSHAPP_VIEW"), ("Add", "PUSHAPP_ADD")]),
            ("CHECKOUT_CATEGORY", [("Cart", "PUSHAPP_CART"), ("Pay", "PUSHAPP_PAY")]),
            ("FORM_ACTION_CATEGORY", [("Save", "PUSHAPP_SAVE"), ("Submit", "PUSHAPP_SUBMIT")]),
            ("DESTRUCTIVE_ACTION_CATEGORY", [("Cancel", "PUSHAPP_CANCEL"), ("Delete", "PUSHAPP_DELETE")]),
            ("CONTACT_CATEGORY", [("Call", "PUSHAPP_CALL"), ("Email", "PUSHAPP_EMAIL")])
        ]

        var categories: Set<UNNotificationCategory> = []

        for (categoryId, actionsInfo) in categoryMap {
            let actions = actionsInfo.map { info in
                UNNotificationAction(identifier: info.id, title: info.title, options: [.foreground])
            }

            let category = UNNotificationCategory(
                identifier: categoryId,
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
            categories.insert(category)
        }

        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    
    private func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first?.rootViewController) -> UIViewController? {
        
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        } else if let tab = base as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        } else if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
    
    
    // Weak wrapper to avoid retaining Coordinator (and hence WKWebView)
    private class WeakInlineCoordinator {
        weak var coordinator: PushAppInlineView.Coordinator?
        init(_ coordinator: PushAppInlineView.Coordinator) { self.coordinator = coordinator }
    }

    // map placeholderId -> array of weak coordinators (support multiple instances for same id)
    private var inlineViews: [String: [WeakInlineCoordinator]] = [:]

    // register
    func registerInlineView(placeholderId: String, coordinator: PushAppInlineView.Coordinator) {
        DispatchQueue.main.async {
            var list = self.inlineViews[placeholderId] ?? []
            // avoid duplicate registrations of same coordinator
            if !list.contains(where: { $0.coordinator === coordinator }) {
                list.append(WeakInlineCoordinator(coordinator))
                self.inlineViews[placeholderId] = list
            }
            self.cleanupInlineViews()
        }
    }

    // unregister specific coordinator (called from Coordinator.deinit)
    func unregisterInlineView(placeholderId: String, coordinator: PushAppInlineView.Coordinator) {
        DispatchQueue.main.async {
            guard var list = self.inlineViews[placeholderId] else { return }
            list.removeAll { $0.coordinator === coordinator || $0.coordinator == nil }
            if list.isEmpty {
                self.inlineViews.removeValue(forKey: placeholderId)
            } else {
                self.inlineViews[placeholderId] = list
            }
        }
    }

    // remove nil entries
    private func cleanupInlineViews() {
        for (key, list) in inlineViews {
            let filtered = list.filter { $0.coordinator?.webView != nil }
            if filtered.isEmpty {
                inlineViews.removeValue(forKey: key)
            } else {
                inlineViews[key] = filtered
            }
        }
    }

    // render HTML into all coordinators registered for this placeholderId
    func renderInlineIfNeeded(placeholderId: String, html: String) {
        DispatchQueue.main.async {
            self.cleanupInlineViews()
            guard let list = self.inlineViews[placeholderId] else { return }
            for weakWrapper in list {
                weakWrapper.coordinator?.loadContent(html)
            }
        }
    }

}





@available(iOS 15.2, *)
public struct PushAppInlineView: UIViewRepresentable {
    public typealias UIViewType = WKWebView

    public let placeholderId: String

    // Coordinator holds a weak reference to the actual WKWebView
    public class Coordinator {
        public weak var webView: WKWebView?
        public let placeholderId: String

        public init(placeholderId: String) {
            self.placeholderId = placeholderId
            // register with SDK manager on creation
            PushApp.shared.registerInlineView(placeholderId: placeholderId, coordinator: self)
        }

        deinit {
            // unregister when coordinator is deallocated
            PushApp.shared.unregisterInlineView(placeholderId: placeholderId, coordinator: self)
        }

        // thread-safe HTML load
        public func loadContent(_ html: String) {
            DispatchQueue.main.async { [weak self] in
                self?.webView?.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    public init(placeholderId: String) {
        self.placeholderId = placeholderId
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(placeholderId: placeholderId)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.webView = webView
        
        PushApp.shared.sendEvent(
            eventName: "widget_open",
            eventData: ["compare": placeholderId]
        )
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // nothing here — content will be injected by PushApp when notification arrives
    }
}

// MARK: - WebSocketManager

@available(iOS 13.0, *)
class WebSocketManager: NSObject {
    private let userId: String
    private let onMessage: ([String: Any]) -> Void
    private var webSocketTask: URLSessionWebSocketTask?
    let slackWebhookURL = URL(string: "https://hooks.slack.com/services/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")!
    @available(iOS 15.2, *)
    private var url: URL {
        let baseUrl: String
        if PushApp.shared.sandbox {
            baseUrl = "https://\(PushApp.shared.tenant).mehery.com"
        } else {
            baseUrl = "https://\(PushApp.shared.tenant).mehery.com"
        }
        return URL(string: baseUrl.replacingOccurrences(of: "https", with: "wss") + "/pushapp")!
    }

    init(userId: String, onMessage: @escaping ([String: Any]) -> Void) {
        self.userId = userId
        self.onMessage = onMessage
    }

    @available(iOS 15.2, *)
    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
        sendAuth()
    }
    
    func slackPrint(_ message: String) {
        // Print to console
        print(message)
        
        // Send to Slack
        var request = URLRequest(url: slackWebhookURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["text": message]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("⚠️ Failed to encode Slack message: \(error)")
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("⚠️ Slack send error: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("⚠️ Slack returned status: \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
    }

    private func sendAuth() {
        let authMessage: [String: Any] = [
            "type": "auth",
            "userId": userId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: authMessage) {
            webSocketTask?.send(.data(data)) { error in
                if let error = error {
                    self.slackPrint("Auth error: \(error)")
                }
            }
        }
    }
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.slackPrint("WebSocket Received JSON (data): \(json)")
                            self.onMessage(json)
                        } else {
                            self.slackPrint("Failed to cast JSON from data to [String: Any]")
                        }
                    } catch {
                        self.slackPrint("JSON parsing error from data: \(error.localizedDescription)")
                    }

                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        do {
                            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                self.slackPrint("WebSocket Received JSON (string): \(json)")
                                self.onMessage(json)
                            } else {
                                self.slackPrint("Failed to cast JSON from string to [String: Any]")
                            }
                        } catch {
                            self.slackPrint("JSON parsing error from string: \(error.localizedDescription)")
                        }
                    } else {
                        self.slackPrint("Failed to convert string to Data")
                    }

                @unknown default:
                    self.slackPrint("Received unknown WebSocket message type")
                }
                // Continue listening for next message
                self.listen()

            case .failure(let error):
                self.slackPrint("WebSocket receive error: \(error.localizedDescription)")
                // Optionally, you can reconnect or handle error here
            }
        }
    }


}

@available(iOS 13.0, *)
extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        self.slackPrint("WebSocket closed")
    }
}

// MARK: - InAppDisplay

@available(iOS 13.0, *)
class InAppDisplay {
    private weak var context: UIViewController?
    private var queue: [[String: Any]] = []
    private var isShowing: Bool = false
    let slackWebhookURL = URL(string: "https://hooks.slack.com/services/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")!

    init(context: UIViewController) {
        self.context = context
        self.slackPrint("✅ InAppDisplay initialized with context: \(String(describing: context))")
    }

    @available(iOS 14.0, *)
    func showInApp(from notifications: [[String: Any]]) {
        self.slackPrint("📥 showInApp called with \(notifications.count) notifications")
        queue.append(contentsOf: notifications)
        showNextIfNeeded()
    }
    
    func slackPrint(_ message: String) {
        // Print to console
        print(message)
        
        // Send to Slack
        var request = URLRequest(url: slackWebhookURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["text": message]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("⚠️ Failed to encode Slack message: \(error)")
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("⚠️ Slack send error: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("⚠️ Slack returned status: \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
    }

    private func showNextIfNeeded() {
        self.slackPrint("🔄 showNextIfNeeded called. isShowing=\(isShowing), queue.count=\(queue.count)")
        guard !isShowing, !queue.isEmpty else {
            self.slackPrint("⏹ Nothing to show or already showing")
            return
        }
        isShowing = true

        let notif = queue.removeFirst()
        self.slackPrint("📤 Preparing notification: \(notif)")
        
        var contactId = ""
        
        if #available(iOS 15.2, *) {
            contactId = PushApp.shared.userId! + "_" + PushApp.shared.getPersistentDeviceId()
        } else {
            // Fallback on earlier versions
        }

        guard let template = notif["template"] as? [String: Any],
              let style = template["style"] as? [String: Any],
              let layout = style["code"] as? String,
              let event = notif["event"] as? [String: Any],
              let messageId = notif["messageId"] as? String,
              let filterId = notif["filterId"] as? String else {
            self.slackPrint("❌ Invalid notification format, skipping")
            isShowing = false
            showNextIfNeeded()
            return
        }

        let html = style["html"] as? String // optionackal

        // 🔔 Call ACK before showing
        if #available(iOS 15.2, *) {
            PushApp.shared.ackInApp(contactId: contactId, messageId: messageId) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    guard success else {
                        self.slackPrint("⚠️ Failed to ack messageId: \(messageId), skipping display")
                        self.isShowing = false
                        self.showNextIfNeeded()
                        return
                    }
                    
                    self.slackPrint("✅ Ack sent for messageId: \(messageId)")
                    self.slackPrint("📐 Layout: \(layout)")
                    
                    if layout.contains("tooltip") {
                        let eventData = event["event_data"] as? [String: Any]
                        var placeholderId = template["code"] as? String ?? ""
                        if let compare = eventData?["compare"] as? String {
                            placeholderId = compare
                        }
                        print(placeholderId)
                        
                        let title = style["line_1"] as? String ?? ""
                        let message = style["line_2"] as? String ?? ""
                        let bgColorHex = style["bg_color"] as? String ?? "#000000"
                        let bgColor = UIColor(hex: bgColorHex)
                        
                        if let targetView = TooltipRegistry.shared.view(for: placeholderId) {
                            var preferences = EasyTipView.Preferences()
                            preferences.drawing.backgroundColor = bgColor
                            preferences.drawing.arrowPosition = .any
                            preferences.positioning.maxWidth = UIScreen.main.bounds.width * 0.8
                            
                            let attributedText = NSMutableAttributedString(
                                string: title + "\n\n",
                                attributes: [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.white]
                            )
                            attributedText.append(NSAttributedString(
                                string: message,
                                attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.white]
                            ))
                            
                            let tipView = EasyTipView(text: attributedText, preferences: preferences, delegate: nil)
                            tipView.show(forView: targetView)
                            self.slackPrint("✅ Tooltip shown for placeholderId: \(placeholderId)")
                            
                            let closeButtonSize: CGFloat = 24
                            let closeButton = UIButton(type: .system)
                            closeButton.frame = CGRect(
                                x: tipView.bounds.width - closeButtonSize - 8,
                                y: 8,
                                width: closeButtonSize,
                                height: closeButtonSize
                            )
                            closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
                            closeButton.layer.cornerRadius = closeButtonSize / 2
                            closeButton.setTitle("✕", for: .normal)
                            closeButton.setTitleColor(.white, for: .normal)
                            closeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
                            closeButton.addTarget(nil, action: #selector(self.closeTooltip(_:)), for: .touchUpInside)
                            tipView.addSubview(closeButton)
                            
                            self.currentTooltip = tipView
                        }
                    } else if layout.contains("inline") {
                        if let html = style["html"] as? String {
                            // placeholder id resolution
                            var placeholderId = template["code"] as? String ?? ""
                            if let eventData = event["event_data"] as? [String: Any],
                               let compare = eventData["compare"] as? String {
                                placeholderId = compare
                            }

                            PushApp.shared.renderInlineIfNeeded(placeholderId: placeholderId, html: html)
                            self.slackPrint("✅ Inline content injected for placeholderId: \(placeholderId)")
                        } else {
                            self.slackPrint("⚠️ inline layout but no html found")
                        }
                        // finish this notification and move to next
                        self.isShowing = false
                        self.showNextIfNeeded()
                    } else if layout.contains("roadblock") {
                        self.showPopup(messageId: messageId,filterId: filterId,html!) { [weak self] in
                            self?.slackPrint("✅ Popup closed")
                            self?.isShowing = false
                            self?.showNextIfNeeded()
                        }
                    } else if layout.contains("bottomsheet") {
                        self.showBottomSheet(messageId: messageId, filterId: filterId,html!) { [weak self] in
                            self?.slackPrint("✅ Bottom Sheet closed")
                            PushApp.shared.trackInAppEvent(messageId: messageId, event: "dismissed") { success in
                                if success {
                                    self?.slackPrint("📩 Dismiss event tracked")
                                }
                            }
                            self?.isShowing = false
                            self?.showNextIfNeeded()
                        }
                    } else if layout.contains("banner") {
                        self.showBanner(messageId: messageId, filterId: filterId,html!) { [weak self] in
                            self?.slackPrint("✅ Banner closed")
                            PushApp.shared.trackInAppEvent(messageId: messageId, event: "dismissed") { success in
                                if success {
                                    self?.slackPrint("📩 Dismiss event tracked")
                                }
                            }
                            self?.isShowing = false
                            self?.showNextIfNeeded()
                        }
                    } else if layout.contains("picture-in-picture") {
                        let v_a = (style["vertical_align"] as? String) ?? "flex_end"
                        let h_a = (style["horizontal_align"] as? String) ?? "flex_end"
                        self.showPictureInPicture(messageId: messageId, filterId: filterId,html!, h_a: h_a, v_a: v_a) { [weak self] in
                            self?.slackPrint("✅ PIP closed")
                            PushApp.shared.trackInAppEvent(messageId: messageId, event: "dismissed") { success in
                                if success {
                                    self?.slackPrint("📩 Dismiss event tracked")
                                }
                            }
                            self?.isShowing = false
                            self?.showNextIfNeeded()
                        }
                    } else if layout.contains("floater") {
                        let v_a = (style["vertical_align"] as? String) ?? "flex_end"
                        let h_a = (style["horizontal_align"] as? String) ?? "flex_end"
                        self.showFloater(html!, h_a: h_a, v_a: v_a) { [weak self] in
                            self?.slackPrint("✅ Floater closed")
                            PushApp.shared.trackInAppEvent(messageId: messageId, event: "dismissed") { success in
                                if success {
                                    self?.slackPrint("📩 Dismiss event tracked")
                                }
                            }
                            self?.isShowing = false
                            self?.showNextIfNeeded()
                        }
                    } else {
                        self.slackPrint("❌ Unknown layout: \(layout)")
                        self.isShowing = false
                        self.showNextIfNeeded()
                    }
                }
            }
        } else {
            // Fallback on earlier versions
        }
    }

    
    // MARK: - Selector for close button
    @objc private func closeTooltip(_ sender: UIButton) {
        currentTooltip?.dismiss()
        currentTooltip = nil
        isShowing = false
        showNextIfNeeded()
    }

    // MARK: - Property to hold current tooltip
    private var currentTooltip: EasyTipView?
    
    
    class ScriptMessageHandler: NSObject, WKScriptMessageHandler {
        private let callback: (String) -> Void
        private let messageId: String  // we need this to track CTA against a specific messageId
        private let filterId: String  // we need this to track CTA against a specific messageId

        init(messageId: String, filterId: String, callback: @escaping (String) -> Void) {
            self.messageId = messageId
            self.filterId = filterId
            self.callback = callback
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                print("📩 JS -> Native message: \(body)")
                
                if let data = body.data(using: .utf8) {
                    do {
                        if let messageObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            
                            // Extract CTA ID from messageObject["data"]["code"]
                            if let dataDict = messageObject["data"] as? [String: Any],
                               let ctaId = dataDict["value"] as? String {
                                
                                if let url = URL(string: ctaId), url.scheme != nil, UIApplication.shared.canOpenURL(url) {
                                        // Case 1: ctaId is a URL → open it
                                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                    } else {
                                        // Case 2: ctaId is just a string → handle accordingly
                                        print("CTA String ID: \(ctaId)")
                                        // e.g., navigate to a screen, call an API, etc.
                                    }
                                
                                // Call your in-app tracking API
                                if #available(iOS 15.2, *) {
                                    PushApp.shared.trackInAppEvent(messageId: messageId,
                                                                   event: "cta", filterId: filterId,
                                                                   ctaId: ctaId) { success in
                                        if success {
                                            print("✅ CTA tracked with ctaId=\(ctaId)")
                                        } else {
                                            print("❌ Failed to track CTA")
                                        }
                                    }
                                } else {
                                    // Fallback on earlier versions
                                }
                            }
                        }
                    } catch {
                        print("❌ Failed to parse JS message JSON: \(error)")
                    }
                }
                
                callback(body) // still returning raw string
            } else if let dict = message.body as? [String: Any] {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let json = String(data: data, encoding: .utf8) {
                    print("📩 JS -> Native message: \(json)")
                    callback(json)
                }
            }
        }
    }


    private func makeWebView(filterId : String,messageId: String, html: String, onMessage: @escaping (String) -> Void) -> WKWebView {
        let contentController = WKUserContentController()

        // 1. Inject your bridge function
        let js = """
        window.handleClick = function(eventType,lab,val) {
          console.log(">>> Patched handleClick called", eventType, val);
          var message = JSON.stringify({
            event: eventType,
            timestamp: Date.now(),
            data: { url: "", label: lab, value: val }
          });
          window.webkit.messageHandlers.inApp.postMessage(message);
        };
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(userScript)

        // 2. Inject autoplay script for iOS
        let autoplayJS = """
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('video').forEach(function(v) {
                v.muted = true;
                v.playsInline = true;
                var playPromise = v.play();
                if (playPromise !== undefined) {
                    playPromise.catch(function(error) {
                        console.log('iOS autoplay blocked', error);
                    });
                }
            });
        });
        """
        let autoplayScript = WKUserScript(source: autoplayJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(autoplayScript)

        // 3. Register message handler
        let handler = ScriptMessageHandler(messageId: messageId,filterId : filterId, callback: onMessage)
        contentController.add(handler, name: "inApp")

        // 4. Create WKWebView with configuration
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = [] // allow autoplay
        } else {
            config.requiresUserActionForMediaPlayback = false
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        // Disable scrolling inside WKWebView
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }


    @available(iOS 15.2, *)
    private func showPopup(messageId : String,filterId : String,_ html: String,
                           onClose: @escaping () -> Void) {
        guard let context = self.context else { return }

        DispatchQueue.main.async {
            // Handler that just closes the popup
            let webView = self.makeWebView(filterId: filterId, messageId: messageId,html: html) { _ in
                context.dismiss(animated: true, completion: onClose)
            }

            let vc = UIViewController()
            vc.view.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            vc.modalPresentationStyle = .overFullScreen
            vc.view.addSubview(webView)

            webView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: vc.view.topAnchor),
                webView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor)
            ])

            // Add close button (manual close)
            let closeBtn = UIButton(type: .custom)
            closeBtn.setTitle("✕", for: .normal)
            closeBtn.setTitleColor(.white, for: .normal)
            closeBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
            closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            closeBtn.layer.cornerRadius = 20
            closeBtn.clipsToBounds = true
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn.addTargetClosure { _ in
                PushApp.shared.trackInAppEvent(messageId: messageId, event: "dismissed") { success in
                    if success {
                        print("📩 Dismiss event tracked")
                    }
                }
                vc.dismiss(animated: true, completion: onClose)
            }
            vc.view.addSubview(closeBtn)

            NSLayoutConstraint.activate([
                closeBtn.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 20),
                closeBtn.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -20),
                closeBtn.widthAnchor.constraint(equalToConstant: 40),
                closeBtn.heightAnchor.constraint(equalToConstant: 40)
            ])

            context.present(vc, animated: true)
        }
    }

    
    
    private func showBottomSheet(messageId: String,filterId: String,_ html: String, onClose: @escaping () -> Void) {
        guard let context = self.context else {
            self.slackPrint("❌ No context for bottom sheet")
            onClose()
            return
        }

        self.slackPrint("📢 Showing bottom sheet")

        DispatchQueue.main.async {
            let vc = UIViewController()
            vc.view.backgroundColor = UIColor.black.withAlphaComponent(0.4) // dim background
            vc.modalPresentationStyle = .overCurrentContext
            vc.modalTransitionStyle = .crossDissolve

            // Container view for sheet
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .white
            container.layer.cornerRadius = 16
            container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            container.clipsToBounds = true
            vc.view.addSubview(container)

            // Keep a reference to bottom constraint
            let bottomConstraint = container.bottomAnchor.constraint(
                equalTo: vc.view.bottomAnchor,
                constant: vc.view.bounds.height * 0.5
            )

            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
                container.heightAnchor.constraint(equalTo: vc.view.heightAnchor, multiplier: 0.5),
                bottomConstraint
            ])

            // WebView (auto-dismiss on JS message)
            let webView = self.makeWebView(filterId: filterId, messageId : messageId,html: html) { _ in
                self.slackPrint("📩 Bottom sheet message received, dismissing")
                vc.dismiss(animated: true, completion: onClose)
            }
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])

            // Close button
            let closeBtn = UIButton(type: .custom)
            closeBtn.setTitle("✕", for: .normal)
            closeBtn.setTitleColor(.white, for: .normal)
            closeBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
            closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            closeBtn.layer.cornerRadius = 20
            closeBtn.clipsToBounds = true
            closeBtn.addTargetClosure { _ in
                self.slackPrint("❌ Bottom sheet close button tapped")
                vc.dismiss(animated: true, completion: onClose)
            }

            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(closeBtn)

            NSLayoutConstraint.activate([
                closeBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                closeBtn.widthAnchor.constraint(equalToConstant: 40),
                closeBtn.heightAnchor.constraint(equalToConstant: 40)
            ])

            // Present VC
            context.present(vc, animated: false) {
                self.slackPrint("✅ Bottom sheet presented")

                // Animate slide-up
                vc.view.layoutIfNeeded()
                bottomConstraint.constant = 0
                UIView.animate(withDuration: 0.3) {
                    vc.view.layoutIfNeeded()
                }
            }
        }
    }


    private func showBanner(messageId : String,filterId : String,_ html: String, onClose: @escaping () -> Void) {
        guard let context = self.context else {
            self.slackPrint("❌ No context for banner")
            onClose()
            return
        }
        self.slackPrint("📢 Showing banner")

        DispatchQueue.main.async {
            var bannerView: WKWebView?
            var closeBtn: UIButton?
            var containerView: UIView?

            // Banner WebView (auto-dismiss on JS message)
            bannerView = self.makeWebView(filterId: filterId, messageId: messageId,html: html) { _ in
                self.slackPrint("📩 Banner message received, dismissing")
                containerView?.removeFromSuperview()
                closeBtn?.removeFromSuperview()
                onClose()
            }

            guard let bannerViewUnwrapped = bannerView else { return }

            // Shadow container
            let shadowContainer = UIView()
            shadowContainer.translatesAutoresizingMaskIntoConstraints = false
            shadowContainer.layer.cornerRadius = 8
            shadowContainer.layer.masksToBounds = false
            shadowContainer.layer.shadowColor = UIColor.black.cgColor
            shadowContainer.layer.shadowOpacity = 0.25
            shadowContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
            shadowContainer.layer.shadowRadius = 6
            containerView = shadowContainer

            context.view.addSubview(shadowContainer)
            NSLayoutConstraint.activate([
                shadowContainer.leadingAnchor.constraint(equalTo: context.view.leadingAnchor, constant: 16),
                shadowContainer.trailingAnchor.constraint(equalTo: context.view.trailingAnchor, constant: -16),
                shadowContainer.topAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                shadowContainer.heightAnchor.constraint(equalToConstant: 100)
            ])

            // Embed webview inside shadow container
            shadowContainer.addSubview(bannerViewUnwrapped)
            bannerViewUnwrapped.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bannerViewUnwrapped.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
                bannerViewUnwrapped.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
                bannerViewUnwrapped.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
                bannerViewUnwrapped.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor)
            ])
            bannerViewUnwrapped.layer.cornerRadius = 8
            bannerViewUnwrapped.clipsToBounds = true

            // Close button
            let btn = UIButton(type: .custom)
            btn.setTitle("✕", for: .normal)
            btn.setTitleColor(.black, for: .normal)
            btn.backgroundColor = UIColor.white.withAlphaComponent(0.7)
            btn.layer.cornerRadius = 12
            btn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn = btn

            context.view.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: shadowContainer.topAnchor, constant: 8),
                btn.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor, constant: -8),
                btn.widthAnchor.constraint(equalToConstant: 24),
                btn.heightAnchor.constraint(equalToConstant: 24)
            ])

            btn.addTargetClosure { _ in
                self.slackPrint("❌ Banner close button tapped")
                shadowContainer.removeFromSuperview()
                btn.removeFromSuperview()
                onClose()
            }
        }
    }



    @available(iOS 15.2, *)
    private func showPictureInPicture(
        messageId: String,
        filterId: String,
        _ html: String,
        h_a: String = "flex_end",
        v_a: String = "flex_end",
        onClose: @escaping () -> Void
    ) {
        guard let context = self.context else {
            self.slackPrint("❌ No context for PIP")
            onClose()
            return
        }
        self.slackPrint("📢 Showing PIP")

        DispatchQueue.main.async {
            // Inner WKWebView
            let pipView = WKWebView()
            pipView.loadHTMLString(html, baseURL: nil)
            pipView.translatesAutoresizingMaskIntoConstraints = false
            pipView.layer.cornerRadius = 8
            pipView.clipsToBounds = true
            pipView.isOpaque = false
            pipView.backgroundColor = .clear
            pipView.scrollView.backgroundColor = .clear
            pipView.scrollView.isScrollEnabled = false
            pipView.scrollView.bounces = false

            // Shadow container
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            container.layer.cornerRadius = 8
            container.layer.masksToBounds = false
            container.layer.shadowColor = UIColor.black.cgColor
            container.layer.shadowOpacity = 0.25
            container.layer.shadowOffset = CGSize(width: 0, height: 4)
            container.layer.shadowRadius = 8

            // Embed WKWebView inside container
            container.addSubview(pipView)
            context.view.addSubview(container)

            // Screen-based size (1/3 width and height)
            let screenBounds = UIScreen.main.bounds
            let pipWidth = screenBounds.width / 3
            let pipHeight = screenBounds.height / 3

            var constraints: [NSLayoutConstraint] = [
                container.widthAnchor.constraint(equalToConstant: pipWidth),
                container.heightAnchor.constraint(equalToConstant: pipHeight),

                pipView.topAnchor.constraint(equalTo: container.topAnchor),
                pipView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                pipView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pipView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ]

            // Vertical alignment
            switch v_a {
            case "flex_start":
                constraints.append(container.topAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.topAnchor, constant: 20))
            case "center":
                constraints.append(container.centerYAnchor.constraint(equalTo: context.view.centerYAnchor))
            case "flex_end":
                constraints.append(container.bottomAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.bottomAnchor, constant: -20))
            default:
                constraints.append(container.bottomAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.bottomAnchor, constant: -20))
            }

            // Horizontal alignment
            switch h_a {
            case "flex_start":
                constraints.append(container.leadingAnchor.constraint(equalTo: context.view.leadingAnchor, constant: 20))
            case "center":
                constraints.append(container.centerXAnchor.constraint(equalTo: context.view.centerXAnchor))
            case "flex_end":
                constraints.append(container.trailingAnchor.constraint(equalTo: context.view.trailingAnchor, constant: -20))
            default:
                constraints.append(container.trailingAnchor.constraint(equalTo: context.view.trailingAnchor, constant: -20))
            }

            NSLayoutConstraint.activate(constraints)

            // Expand button
            let expandButton = UIButton(type: .system)
            let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: config)
            expandButton.setImage(image, for: .normal)
            expandButton.tintColor = .white
            expandButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            expandButton.layer.cornerRadius = 15
            expandButton.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(expandButton)
            NSLayoutConstraint.activate([
                expandButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
                expandButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
                expandButton.widthAnchor.constraint(equalToConstant: 30),
                expandButton.heightAnchor.constraint(equalToConstant: 30)
            ])

            if #available(iOS 14.0, *) {
                expandButton.addAction(UIAction { [weak self] _ in
                    self?.slackPrint("🔄 PIP expand button tapped")
                    container.removeFromSuperview()
                    onClose()
                    self?.showPopup(messageId: messageId, filterId: filterId,html, onClose: {})
                }, for: .touchUpInside)
            }
        }
    }

    
    private func showFloater(
        _ html: String,
        h_a: String = "flex_end",
        v_a: String = "flex_end",
        onClose: @escaping () -> Void
    ) {
        guard let context = self.context else {
            self.slackPrint("❌ No context for Floater")
            onClose()
            return
        }
        self.slackPrint("📢 Showing Floater")

        DispatchQueue.main.async {
            let floaterView = WKWebView()
            floaterView.loadHTMLString(html, baseURL: nil)
            floaterView.translatesAutoresizingMaskIntoConstraints = false
            floaterView.layer.cornerRadius = 8
            floaterView.clipsToBounds = true
            floaterView.isOpaque = false
            floaterView.backgroundColor = .clear
            floaterView.scrollView.backgroundColor = .clear
            floaterView.scrollView.isScrollEnabled = false
            floaterView.scrollView.bounces = false

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            container.addSubview(floaterView)

            context.view.addSubview(container)

            // Screen-based size (1/3 width and height)
            let screenBounds = UIScreen.main.bounds
            let floaterWidth = screenBounds.width / 3
            let floaterHeight = screenBounds.height / 3

            var constraints: [NSLayoutConstraint] = [
                container.widthAnchor.constraint(equalToConstant: floaterWidth),
                container.heightAnchor.constraint(equalToConstant: floaterHeight),

                floaterView.topAnchor.constraint(equalTo: container.topAnchor),
                floaterView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                floaterView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                floaterView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ]

            // Vertical alignment
            switch v_a {
            case "flex_start":
                constraints.append(container.topAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.topAnchor, constant: 20))
            case "center":
                constraints.append(container.centerYAnchor.constraint(equalTo: context.view.centerYAnchor))
            case "flex_end":
                constraints.append(container.bottomAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.bottomAnchor, constant: -20))
            default:
                constraints.append(container.bottomAnchor.constraint(equalTo: context.view.safeAreaLayoutGuide.bottomAnchor, constant: -20))
            }

            // Horizontal alignment
            switch h_a {
            case "flex_start":
                constraints.append(container.leadingAnchor.constraint(equalTo: context.view.leadingAnchor, constant: 20))
            case "center":
                constraints.append(container.centerXAnchor.constraint(equalTo: context.view.centerXAnchor))
            case "flex_end":
                constraints.append(container.trailingAnchor.constraint(equalTo: context.view.trailingAnchor, constant: -20))
            default:
                constraints.append(container.trailingAnchor.constraint(equalTo: context.view.trailingAnchor, constant: -20))
            }

            NSLayoutConstraint.activate(constraints)

            // 👉 Add dragging gesture
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(self.handleFloaterPan(_:)))
            container.addGestureRecognizer(panGesture)
        }
    }

    @objc private func handleFloaterPan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view.superview)

        switch gesture.state {
        case .changed:
            view.center = CGPoint(
                x: view.center.x + translation.x,
                y: view.center.y + translation.y
            )
            gesture.setTranslation(.zero, in: view.superview)
        default:
            break
        }
    }
}

typealias UIControlTargetClosure = (UIControl) -> ()

class ClosureSleeve {
    let closure: UIControlTargetClosure
    init(_ closure: @escaping UIControlTargetClosure) {
        self.closure = closure
    }
    @objc func invoke(_ sender: UIControl) {
        closure(sender)
    }
}

extension UIControl {
    func addTargetClosure(_ closure: @escaping UIControlTargetClosure) {
        let sleeve = ClosureSleeve(closure)
        addTarget(sleeve, action: #selector(ClosureSleeve.invoke(_:)), for: .touchUpInside)
        objc_setAssociatedObject(self, String(format: "[%d]", arc4random()), sleeve, .OBJC_ASSOCIATION_RETAIN)
    }
}


private extension UIViewController {
    @objc func dismissVC() {
        dismiss(animated: true)
    }
}

@available(iOS 15.2, *)
public struct PageTrackingModifier: SwiftUI.ViewModifier {
   
    let name: String

    @available(iOS 15.2, *)
    public func body(content: Content) -> some View {
        content
            .onAppear {
                PushApp.shared.sendEvent(eventName: "page_open", eventData: ["page": name,"compare" : name])
            }
            .onDisappear {
                PushApp.shared.sendEvent(eventName: "page_closed", eventData: ["page": name, "compare" : name])
            }
    }
}

@available(iOS 15.2, *)
public extension View {
    func trackPage(name: String) -> some View {
        self.modifier(PageTrackingModifier(name: name))
    }
}


// MARK: - Tooltip Modifier (placeholder only)
public struct TooltipModifier: ViewModifier {
    let placeholderId: String?

    public func body(content: Content) -> some View {
        content
            .background(
                TooltipAnchor(
                    content: content,
                    placeholderId: placeholderId
                )
            )
    }
}

// MARK: - Tooltip Anchor (placeholder)
public struct TooltipAnchor<Content: View>: UIViewRepresentable {
    let content: Content
    let placeholderId: String?

    public func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Register the view in the global registry using placeholderId
        if let id = placeholderId {
            TooltipRegistry.shared.register(view: hosting.view, for: id)
//            self.slackPrint("✅ Registered placeholder view for id: \(id)")
        }

        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - View Extension
public extension View {
    func tooltip(placeholderId: String?) -> some View {
        self.modifier(TooltipModifier(placeholderId: placeholderId))
    }
}

// MARK: - Global Tooltip Registry
public class TooltipRegistry {
    public static let shared = TooltipRegistry()
    private init() {}

    private var viewMap = [String: UIView]()

    public func register(view: UIView, for key: String) {
        viewMap[key] = view
    }

    public func view(for key: String) -> UIView? {
        return viewMap[key]
    }

    public func unregister(key: String) {
        viewMap.removeValue(forKey: key)
    }
}


extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

@available(iOS 15.2, *)
extension PushApp {
    private static let deviceIdKey = "pushapp_device_id"

    /// Returns a persistent device id (vendor id + timestamp) for the whole app lifecycle
    public func getPersistentDeviceId() -> String {
        if let saved = UserDefaults.standard.string(forKey: PushApp.deviceIdKey) {
            return saved
        }

        // Base id = vendor id or random UUID
        let baseId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let newId = "\(baseId)_\(timestamp)"

        // Save permanently
        UserDefaults.standard.setValue(newId, forKey: PushApp.deviceIdKey)
        self.slackPrint("🆕 Generated new persistent device id: \(newId)")

        return newId
    }
}







