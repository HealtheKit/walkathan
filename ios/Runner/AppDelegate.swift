import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // A stable id for THIS phone + this vendor, used to bind the phone to one
    // walker profile. It survives reinstalling the app while any app from the
    // same vendor stays installed.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "walkathon/device", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method == "getId" {
          result(UIDevice.current.identifierForVendor?.uuidString)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
