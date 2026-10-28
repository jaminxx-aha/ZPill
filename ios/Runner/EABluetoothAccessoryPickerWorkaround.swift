import ObjectiveC
import UIKit

// Adapted from Navideck/universal_bluetooth_classic (BSD-3-Clause).
// See THIRD_PARTY_NOTICES.md for the full notice.
//
// EAAccessoryManager's picker reads AppDelegate.window and, before iOS 26.5,
// creates a scene-less UIWindow. Neither works correctly with UIScene by
// default. Keep the compatibility state scoped to an active picker call.
enum EABluetoothAccessoryPickerWorkaround {
  private static let requiresSceneLessWindowFix =
    !ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
    )

  private static let teardownWatchdogInterval: TimeInterval = 60

  private static var activeSessions = Set<Int>()
  private static var nextSessionID = 0
  private static var didBindWindow = false
  private static var isSwizzled = false
  private static var teardownWatchdog: DispatchWorkItem?

  /// Prepares the compatibility window before presenting the picker.
  /// Must be called on the main thread.
  static func begin() -> Int {
    guard #available(iOS 13.0, *) else { return 0 }
    nextSessionID += 1
    let sessionID = nextSessionID
    if activeSessions.isEmpty {
      bindSceneWindowToAppDelegate()
      if requiresSceneLessWindowFix {
        installWindowSwizzle()
      }
      scheduleTeardownWatchdog()
    }
    activeSessions.insert(sessionID)
    return sessionID
  }

  /// Restores compatibility state after the picker completes.
  /// Must be called on the main thread.
  static func end(_ sessionID: Int) {
    guard #available(iOS 13.0, *) else { return }
    guard activeSessions.remove(sessionID) != nil,
          activeSessions.isEmpty
    else {
      return
    }
    teardown()
  }

  @available(iOS 13.0, *)
  private static func scheduleTeardownWatchdog() {
    teardownWatchdog?.cancel()
    let item = DispatchWorkItem { teardown() }
    teardownWatchdog = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + teardownWatchdogInterval,
      execute: item
    )
  }

  @available(iOS 13.0, *)
  private static func teardown() {
    teardownWatchdog?.cancel()
    teardownWatchdog = nil
    activeSessions.removeAll()
    removeWindowSwizzle()
    restoreAppDelegateWindow()
  }

  @available(iOS 13.0, *)
  private static func bindSceneWindowToAppDelegate() {
    guard let appDelegate = UIApplication.shared.delegate as? NSObject,
          appDelegate.responds(to: NSSelectorFromString("window")),
          appDelegate.responds(to: NSSelectorFromString("setWindow:")),
          appDelegate.value(forKey: "window") as? UIWindow == nil,
          let window = activeSceneKeyWindow()
    else {
      return
    }
    appDelegate.setValue(window, forKey: "window")
    didBindWindow = true
  }

  @available(iOS 13.0, *)
  private static func restoreAppDelegateWindow() {
    guard didBindWindow else { return }
    didBindWindow = false
    guard let appDelegate = UIApplication.shared.delegate as? NSObject else {
      return
    }
    appDelegate.setValue(nil, forKey: "window")
  }

  @available(iOS 13.0, *)
  private static func activeSceneKeyWindow() -> UIWindow? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
  }

  @available(iOS 13.0, *)
  private static func installWindowSwizzle() {
    guard !isSwizzled else { return }
    guard let original = class_getInstanceMethod(
      UIWindow.self,
      #selector(UIWindow.makeKeyAndVisible)
    ),
      let replacement = class_getInstanceMethod(
        UIWindow.self,
        #selector(UIWindow.ea_makeKeyAndVisible)
      )
    else {
      return
    }
    method_exchangeImplementations(original, replacement)
    isSwizzled = true
  }

  @available(iOS 13.0, *)
  private static func removeWindowSwizzle() {
    guard isSwizzled else { return }
    guard let original = class_getInstanceMethod(
      UIWindow.self,
      #selector(UIWindow.makeKeyAndVisible)
    ),
      let replacement = class_getInstanceMethod(
        UIWindow.self,
        #selector(UIWindow.ea_makeKeyAndVisible)
      )
    else {
      return
    }
    method_exchangeImplementations(original, replacement)
    isSwizzled = false
  }
}

@available(iOS 13.0, *)
private extension UIWindow {
  @objc func ea_makeKeyAndVisible() {
    if windowScene == nil {
      windowScene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
    }
    ea_makeKeyAndVisible()
  }
}
