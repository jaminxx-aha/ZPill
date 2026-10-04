import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "GalleryPlugin") {
      GalleryPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "UsbHostPlugin") {
      UsbHostPlugin.register(with: registrar)
    }
  }
}
