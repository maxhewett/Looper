import AppKit
import ServiceManagement

// Keep the delegate in file scope so the status item stays alive for the full
// application lifetime. `NSApplication.delegate` is not the object that should
// own our menu bar state.
@main
enum LooperApp {
    private static let appDelegate = AppDelegate()
    private static let helperPlistName = "com.maxhewett.Looper.helper.plist"

    static var packagedLoginAgent: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchAgents/com.maxhewett.Looper.menu-bar.plist")
    }

    static var runAtLogin: Bool {
        UserDefaults.standard.object(forKey: "RunAtLogin") as? Bool ?? true
    }

    static func main() {
        if handleCommandLineMode() {
            return
        }

        // Older packages enrolled the app separately in each user's login items.
        if packagedLoginAgent, Bundle.main.bundleURL.path == "/Applications/Looper.app",
           SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        if CommandLine.arguments.contains("--login-agent") && !runAtLogin { return }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }

    /// Package scripts can invoke these commands without starting the menu bar
    /// UI. The registration still belongs to the signed app bundle, which is
    /// what macOS uses for Background App Activity attribution.
    private static func handleCommandLineMode() -> Bool {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard arguments.contains("--register-helper")
            || arguments.contains("--unregister-helper")
            || arguments.contains("--helper-status") else {
            return false
        }

        if LooperPaths.usesDeviceHelper && !arguments.contains("--unregister-helper") {
            print("Looper uses the package-managed system daemon.")
            Foundation.exit(0)
        }
        let service = SMAppService.daemon(plistName: helperPlistName)

        do {
            if arguments.contains("--register-helper") {
                fputs("Install Looper.pkg to set up the device helper.\n", stderr)
                Foundation.exit(1)
            } else if arguments.contains("--unregister-helper") {
                try service.unregister()
                print("Looper helper unregistered.")
            } else {
                print("Looper helper status: \(service.status.rawValue)")
            }
            Foundation.exit(0)
        } catch {
            fputs("Looper helper command failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

}
