import SwiftUI
import PushApp_IOS

struct ContentView: View {
    @State private var isLoggedIn: Bool = false

    var body: some View {
        NavigationView {
            if isLoggedIn {
                SecondScreen()
            } else {
                LoginScreen(isLoggedIn: $isLoggedIn)
            }
        }
        .onAppear {
            // Initialize SDK
            PushApp.shared.initialize(identifier: "demo$demo_1753805479315")

            // Check persisted login
            if let savedUserId = UserDefaults.standard.string(forKey: "pushapp_user_id") {
//                PushApp.shared.login(userId: savedUserId)
                isLoggedIn = true
                PushApp.shared.sendEvent(eventName: "widget_open", eventData: ["compare": "center"])
            }
        }
    }
}

// MARK: - Screen 1: Login
struct LoginScreen: View {
    @State private var domain: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @Binding var isLoggedIn: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Login")
                .font(.largeTitle)
                .padding(.bottom, 40)

            TextField("Domain", text: $domain)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)

            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)

            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button(action: login) {
                Text("Login")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top, 20)
        }
        .padding()
        .trackPage(name: "ScreenOne")
    }

    private func login() {
        guard !username.isEmpty else { return }

        // Call PushApp SDK login
        PushApp.shared.login(userId: username)
        PushApp.shared.sendEvent(eventName: "EVENT_LOGIN_SUCCESS", eventData: ["user_name": username])
        
        

        // Save login for persistence
        UserDefaults.standard.setValue(username, forKey: "pushapp_user_id")
        isLoggedIn = true
    }
}

// MARK: - Screen 2: Post-login Test
// MARK: - Example SecondScreen
struct SecondScreen: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.ignoresSafeArea()

                VStack {
                    // Top welcome label
                    Text("Welcome \(PushApp.shared.getPersistentDeviceId())")
                        .font(.headline)
                        .padding(.top, 40)
                    
                    
                    Spacer()

                    // Center placeholder with tooltip
                    VStack(spacing: 8) {
                        Text("C")
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .tooltip(placeholderId: "center")

                        // Instruction label
                        Text("create tool tip with widget_open and value as center to see tooltip here")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    Spacer()
                    
                    PushAppInlineView(placeholderId: "login_banner")
                                    .frame(width: 300, height: 200)
                    Spacer()
                }
            }
        }
        .trackPage(name: "login")
    }
}











