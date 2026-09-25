/*  ForjaApp.swift — the shell. Deliberately tiny: the app IS La Forja, and every screen it has is a
    screen index.html already draws. What lives natively is only what a web page cannot do: the
    debrief mic (Speech.swift), a rest timer that buzzes a locked phone, a screen that stays lit
    through a workout, haptics, the durable vault, bundled fonts and demos, and a real icon. */
import SwiftUI
import UserNotifications

/// A rest notification is for a phone in a pocket. With the app on screen the page already buzzes
/// and shows GO, so a banner on top of that would be a second alarm for one event.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

@main
struct ForjaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            ForgeView()
                .ignoresSafeArea()           // the page owns its insets via env(safe-area-inset-*)
                .background(Color(red: 0x17 / 255.0, green: 0x12 / 255.0, blue: 0x0f / 255.0))   // soot: a cold launch is never white
                .preferredColorScheme(.dark)
        }
    }
}
