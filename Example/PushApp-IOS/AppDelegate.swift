import UIKit
import ActivityKit
import UserNotifications
import PushApp_IOS

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification authorization
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            print(granted ? "Push notifications granted" : "Push notifications denied")
        }
                
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }
    
    @available(iOS 16.1, *)
        func startLiveActivity(userInfo: [AnyHashable: Any]) {
            Task {
                var imageFileName: String? = nil
                
                // 1️⃣ Download and save image to App Group
                if let imageURLString = userInfo["imageUrl"] as? String,
                   let url = URL(string: imageURLString),
                   let data = try? await URLSession.shared.data(from: url).0,
                   let uiImage = UIImage(data: data) {
                    
                    imageFileName = saveImageToAppGroup(uiImage, named: "abc")
                    
                }
                
                // 2️⃣ Extract content state fields
                let state = DeliveryActivityAttributes.ContentState(
                    message1: userInfo["message1"] as? String ?? "",
                    message2: userInfo["message2"] as? String ?? "",
                    message3: userInfo["message3"] as? String ?? "",
                    message1FontSize: userInfo["message1FontSize"] as? Double ?? 14,
                    message1FontColorHex: userInfo["message1FontColorHex"] as? String ?? "#000000",
                    line1_font_text_styles: userInfo["line1_text_styles"] as? [String] ?? ["bold"],
                    message2FontSize: userInfo["message2FontSize"] as? Double ?? 14,
                    message2FontColorHex: userInfo["message2FontColorHex"] as? String ?? "#000000",
                    line2_font_text_styles: userInfo["line2_text_styles"] as? [String] ?? ["italic"],
                    message3FontSize: userInfo["message3FontSize"] as? Double ?? 14,
                    message3FontColorHex: userInfo["message3FontColorHex"] as? String ?? "#000000",
                    line3_font_text_styles: userInfo["line3_text_styles"] as? [String] ?? ["underline"],
                    backgroundColorHex: userInfo["backgroundColorHex"] as? String ?? "#FFFFFF",
                    fontColorHex: userInfo["fontColorHex"] as? String ?? "#000000",
                    progressColorHex: userInfo["progressColorHex"] as? String ?? "#0000FF",
                    fontSize: userInfo["fontSize"] as? Double ?? 14,
                    progressPercent: userInfo["progressPercent"] as? Double ?? 0,
                    align: userInfo["align"] as? String ?? "left",
                    bg_color_gradient: userInfo["bg_color_gradient"] as? String ?? "",
                    bg_color_gradient_dir: userInfo["bg_color_gradient_dir"] as? String ?? "",
                    imageFileName: imageFileName // only file name
                )
                
                // 3️⃣ Optional toast
//                var message = "Unable to stringify userInfo"
//
//                if let jsonData = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted]),
//                   let jsonString = String(data: jsonData, encoding: .utf8) {
//                    message = jsonString
//                }

                // Optionally truncate if too long
//                let maxLength = 400
//                let toastMessage = String(message.prefix(maxLength))

//                showToast(message: message)
                
                // 4️⃣ Start Live Activity
                do {
                    let activity = try Activity<DeliveryActivityAttributes>.request(
                        attributes: DeliveryActivityAttributes(),
                        contentState: state,
                        pushType: .token
                    )
                    print("Started Live Activity: \(activity.id)")
                } catch {
                    print("Live Activity start error: \(error)")
                }
            }
        }
        
        // MARK: - Save image to App Group
        func saveImageToAppGroup(_ image: UIImage, named name: String) -> String? {
            // Compression quality: 1.0 = best quality
            guard let data = UIImageJPEGRepresentation(image, 1.0),
                  let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.mehery.ios.sdk") else {
                print("❌ Could not get image data or container URL")
                return nil
            }

            let fileName = "\(name).jpg"
            let fileURL = containerURL.appendingPathComponent(fileName)

            do {
                try data.write(to: fileURL)
                print("✅ Saved image at path: \(fileURL.path)")
                return fileName
            } catch {
                print("❌ Failed to save image: \(error)")
                return nil
            }
        }


        
        /// Shows a simple toast message on top of the main window
        func showToast(message: String, duration: TimeInterval = 2.0) {
            DispatchQueue.main.async {
                guard let window = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .first?.windows.first else {
                    print("❌ Could not find main window for toast")
                    return
                }

                // Create label
                let toastLabel = UILabel()
                toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
                toastLabel.textColor = .white
                toastLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
                toastLabel.textAlignment = .center
                toastLabel.text = message
                toastLabel.numberOfLines = 0
                toastLabel.alpha = 0.0
                toastLabel.layer.cornerRadius = 10
                toastLabel.clipsToBounds = true

                // Size & position
                let horizontalPadding: CGFloat = 20
                let verticalPadding: CGFloat = 10
                let maxWidth = window.frame.width - 2 * horizontalPadding
                let textSize = toastLabel.sizeThatFits(CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
                toastLabel.frame = CGRect(
                    x: horizontalPadding,
                    y: window.safeAreaInsets.top + 10,
                    width: maxWidth,
                    height: textSize.height + verticalPadding * 2
                )

                window.addSubview(toastLabel)

                // Animate in/out
                UIView.animate(withDuration: 0.3, animations: {
                    toastLabel.alpha = 1.0
                }) { _ in
                    UIView.animate(withDuration: 0.3, delay: duration, options: [], animations: {
                        toastLabel.alpha = 0.0
                    }) { _ in
                        toastLabel.removeFromSuperview()
                    }
                }
            }
        }

        
        func application(_ application: UIApplication,
                         didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                         fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
            print("Received silent push:", userInfo)

            if #available(iOS 16.1, *) {
                startLiveActivity(userInfo: userInfo)
            }

            completionHandler(.newData)
        }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        print("Received notification with ID = \(id)")
        
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        print(userInfo)
        
        // Handle action button URL if any
        if let buttons = userInfo["buttons"] as? [[String: Any]] {
            if let matchingButton = buttons.first(where: { $0["id"] as? String == actionId }),
               let urlString = matchingButton["url"] as? String,
               let url = URL(string: urlString),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        completionHandler()
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushApp.shared.handleDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }

    // Called when a notification is delivered to a foreground app
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner, sound, badge even if app is active
        print("Test")
        completionHandler([.banner, .badge, .sound, .list])
    }
}
