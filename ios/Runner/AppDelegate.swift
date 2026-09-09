import AVFoundation
import Flutter
import UIKit
import SwiftUI
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var downloadContinuedProcessingChannel: FlutterMethodChannel?
  private var downloadChunkProgressObserver: NSObjectProtocol?
  private var liquidGlassPresenterChannel: FlutterMethodChannel?
  private var persistentGlassHeaderChannel: FlutterMethodChannel?
  private var persistentGlassHeaderController: ApplePersistentGlassHeaderNativeController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    DownloadNativeWaitingQueue.installUrlSessionHook()
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("[AppDelegate] Audio session error: \(error)")
    }
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        if granted {
          print("[AppDelegate] Notification permission granted")
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// URLSession wakes the process when a background download finishes. Start the
  /// next waiter on the plugin session (via the swizzled delegate) **before**
  /// this completion handler runs. Flutter is never what starts the file.
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    DownloadNativeWaitingQueue.installUrlSessionHook()
    super.application(
      application,
      handleEventsForBackgroundURLSession: identifier,
      completionHandler: completionHandler
    )
  }

  // This is required to show notifications while the app is in the foreground
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()

    let persistentHeaderChannel = FlutterMethodChannel(
      name: "com.animewitcher.app/persistent_glass_header",
      binaryMessenger: messenger
    )
    // With Flutter's UIScene lifecycle, AppDelegate.window can stay nil because
    // the scene owns the window. Resolve the UIViewController that is actually
    // displaying this Flutter engine through its plugin registrar instead.
    // Keep AppDelegate.window only as a legacy fallback.
    let persistentHeaderRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AnimeWitcherPersistentGlassHeaderHost"
    )
    let persistentHeaderController = ApplePersistentGlassHeaderNativeController(
      channel: persistentHeaderChannel,
      hostViewProvider: { [weak self] in
        persistentHeaderRegistrar?.viewController?.view
          ?? self?.window?.rootViewController?.view
      }
    )
    persistentGlassHeaderChannel = persistentHeaderChannel
    persistentGlassHeaderController = persistentHeaderController
    persistentHeaderChannel.setMethodCallHandler { [weak persistentHeaderController] call, result in
      switch call.method {
      case "update":
        persistentHeaderController?.apply(arguments: call.arguments)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if let glassRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AnimeWitcherAppleLiquidGlass"
    ) {
      glassRegistrar.register(
        AppleLiquidGlassViewFactory(),
        withId: "com.animewitcher.app/liquid_glass"
      )
      glassRegistrar.register(
        AppleSearchGlassActionsViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/search_glass_actions"
      )
      glassRegistrar.register(
        AppleNativeTabBarViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/native_tab_bar"
      )
      glassRegistrar.register(
        AppleNativeGlassButtonViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/native_glass_button"
      )
      glassRegistrar.register(
        AppleNativeToolbarViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/native_toolbar"
      )
      glassRegistrar.register(
        AppleNativeSearchFieldViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/native_search_field"
      )
      glassRegistrar.register(
        AppleNativeMenuButtonViewFactory(messenger: messenger),
        withId: "com.animewitcher.app/native_menu_button"
      )
    }

    let glassPresenter = FlutterMethodChannel(
      name: "com.animewitcher.app/liquid_glass_presenter",
      binaryMessenger: messenger
    )
    glassPresenter.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        if #available(iOS 26.0, *) {
          result(true)
        } else {
          result(false)
        }

      case "showSearchSort":
        guard #available(iOS 26.0, *) else {
          result(FlutterError(
            code: "LIQUID_GLASS_UNAVAILABLE",
            message: "Native Liquid Glass requires iOS 26 or later.",
            details: nil
          ))
          return
        }
        guard let arguments = call.arguments as? [String: Any],
              let presenter = animeWitcherTopViewController() else {
          result(FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Unable to present the native sort interface.",
            details: nil
          ))
          return
        }
        presentAppleSearchSort(from: presenter, arguments: arguments, result: result)

      case "showSearchFilters":
        guard #available(iOS 26.0, *) else {
          result(FlutterError(
            code: "LIQUID_GLASS_UNAVAILABLE",
            message: "Native Liquid Glass requires iOS 26 or later.",
            details: nil
          ))
          return
        }
        guard let arguments = call.arguments as? [String: Any],
              let presenter = animeWitcherTopViewController() else {
          result(FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Unable to present the native filter interface.",
            details: nil
          ))
          return
        }
        presentAppleSearchFilters(from: presenter, arguments: arguments, result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    liquidGlassPresenterChannel = glassPresenter

    let channel = FlutterMethodChannel(
      name: "com.animewitcher.app/download_continued_processing",
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { call, result in
#if os(iOS)
      if call.method == "persistNativeQueue" || call.method == "persistWaitingQueue" {
        let arguments = call.arguments as? [String: Any] ?? [:]
        DownloadNativeWaitingQueue.persist(from: arguments)
        result(true)
        return
      }

      guard #available(iOS 26.0, *) else {
        result(false)
        return
      }

      guard let arguments = call.arguments as? [String: Any],
            let taskId = arguments["taskId"] as? String else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "taskId is required",
            details: nil
          )
        )
        return
      }

      Task { @MainActor in
        do {
          let manager = DownloadContinuedProcessingManager.shared

          switch call.method {
          case "start":
            guard let displayName = arguments["displayName"] as? String else {
              result(
                FlutterError(
                  code: "INVALID_ARGUMENTS",
                  message: "displayName is required",
                  details: nil
                )
              )
              return
            }

            let progress =
              (arguments["progress"] as? NSNumber)?.doubleValue ?? 0.0
            let totalBytes =
              (arguments["totalBytes"] as? NSNumber)?.int64Value ?? -1
            let transferredBytes =
              (arguments["transferredBytes"] as? NSNumber)?.int64Value ?? -1
            let completedCount =
              (arguments["completedCount"] as? NSNumber)?.intValue ?? 0
            let batchTotal =
              (arguments["batchTotal"] as? NSNumber)?.intValue ?? 1
            let speedBytesPerSecond =
              (arguments["speedBytesPerSecond"] as? NSNumber)?.doubleValue ?? 0
            let currentIndex =
              (arguments["currentIndex"] as? NSNumber)?.intValue ?? 0

            let identifier = try manager.start(
              taskId: taskId,
              displayName: displayName,
              progress: progress,
              totalBytes: totalBytes,
              transferredBytes: transferredBytes,
              completedCount: completedCount,
              batchTotal: batchTotal,
              speedBytesPerSecond: speedBytesPerSecond,
              currentIndex: currentIndex
            )
            if let identifier {
              result(identifier)
            } else {
              result(false)
            }

          case "update":
            let progress =
              (arguments["progress"] as? NSNumber)?.doubleValue ?? 0.0
            let totalBytes =
              (arguments["totalBytes"] as? NSNumber)?.int64Value ?? -1
            manager.update(
              taskId: taskId,
              progress: progress,
              totalBytes: totalBytes,
              transferredBytes: (arguments["transferredBytes"] as? NSNumber)?.int64Value ?? -1,
              completedCount: (arguments["completedCount"] as? NSNumber)?.intValue ?? -1,
              batchTotal: (arguments["batchTotal"] as? NSNumber)?.intValue ?? -1,
              speedBytesPerSecond: (arguments["speedBytesPerSecond"] as? NSNumber)?.doubleValue ?? -1,
              displayName: arguments["displayName"] as? String ?? "",
              currentIndex: (arguments["currentIndex"] as? NSNumber)?.intValue ?? -1
            )
            result(true)

          case "finish":
            let success = arguments["success"] as? Bool ?? false
            let status = arguments["status"] as? String ?? "failed"
            let endSession = arguments["endSession"] as? Bool ?? false
            manager.finish(
              taskId: taskId,
              success: success,
              status: status,
              endSession: endSession
            )
            result(true)

          case "stop":
            manager.stop(
              taskId: taskId,
              endSession: arguments["endSession"] as? Bool ?? false
            )
            result(true)

          default:
            result(FlutterMethodNotImplemented)
          }
        } catch {
          result(
            FlutterError(
              code: "CONTINUED_PROCESSING_ERROR",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
#else
      result(false)
#endif
    }


#if os(iOS)
    if let previous = downloadChunkProgressObserver {
      NotificationCenter.default.removeObserver(previous)
    }
    downloadChunkProgressObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("AnimeWitcherBackgroundDownloaderChunkUpdate"),
      object: nil,
      queue: .main
    ) { [weak channel] notification in
      guard let values = notification.userInfo,
            let parentTaskId = values["parentTaskId"] as? String,
            let chunkTaskId = values["chunkTaskId"] as? String,
            !parentTaskId.isEmpty,
            !chunkTaskId.isEmpty else { return }

      var arguments: [String: Any] = [
        "parentTaskId": parentTaskId,
        "chunkTaskId": chunkTaskId,
      ]
      if let progress = values["progress"] as? NSNumber {
        arguments["progress"] = progress.doubleValue
      }
      if let status = values["status"] as? NSNumber {
        arguments["status"] = status.intValue
      }
      if let written = values["writtenBytes"] as? NSNumber {
        arguments["writtenBytes"] = written.int64Value
      }
      if let expected = values["expectedBytes"] as? NSNumber {
        arguments["expectedBytes"] = expected.int64Value
      }
      if let speed = values["speedBytesPerSecond"] as? NSNumber {
        arguments["speedBytesPerSecond"] = speed.doubleValue
      }
      if let completed = values["completed"] as? Bool {
        arguments["completed"] = completed
      }
      channel?.invokeMethod("chunkUpdate", arguments: arguments)
    }
#endif

#if os(iOS)
    if #available(iOS 26.0, *) {
      DownloadContinuedProcessingManager.shared.cancellationHandler = {
        [weak channel] taskId in
        channel?.invokeMethod(
          "cancel",
          arguments: ["taskId": taskId]
        )
      }
    }
#endif

    downloadContinuedProcessingChannel = channel
  }
}

private func animeWitcherUIColor(_ value: Any?, fallback: UIColor = .label) -> UIColor {
  guard let number = value as? NSNumber else { return fallback }
  let argb = number.uint32Value
  let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
  let red = CGFloat((argb >> 16) & 0xFF) / 255.0
  let green = CGFloat((argb >> 8) & 0xFF) / 255.0
  let blue = CGFloat(argb & 0xFF) / 255.0
  return UIColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func animeWitcherMenuTitle(_ label: String, isRtl: Bool) -> String {
  guard isRtl else { return label }
  // Keep Arabic titles as one RTL run inside UIKit's LTR UIMenu layout.
  return "\u{202B}\(label)\u{202C}"
}

private final class AppleNativeTabBarViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleNativeTabBarPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AppleNativeTabBarPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let rootView: UIView
  private let tabBar = UITabBar()
  private let channel: FlutterMethodChannel
  private var itemIds: [String] = []

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = UIView(frame: frame)
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/native_tab_bar/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    tabBar.isTranslucent = true
    rootView.addSubview(tabBar)
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      tabBar.topAnchor.constraint(equalTo: rootView.topAnchor),
      tabBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
    apply(arguments: args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.apply(arguments: call.arguments)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { rootView }

  private func apply(arguments: Any?) {
    guard let values = arguments as? [String: Any] else { return }
    let items = values["items"] as? [[String: Any]] ?? []
    let selectedId = values["selectedId"] as? String
    itemIds = items.compactMap { $0["id"] as? String }

    let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    tabBar.items = items.map { item in
      let title = item["label"] as? String
      let symbol = item["symbol"] as? String ?? "circle"
      let selectedSymbol = item["selectedSymbol"] as? String ?? symbol
      return UITabBarItem(
        title: title,
        image: UIImage(systemName: symbol, withConfiguration: symbolConfiguration),
        selectedImage: UIImage(systemName: selectedSymbol, withConfiguration: symbolConfiguration)
      )
    }

    if let tint = values["tintColor"] {
      tabBar.tintColor = animeWitcherUIColor(tint, fallback: .systemBlue)
    }
    if let selectedId,
       let index = itemIds.firstIndex(of: selectedId),
       let items = tabBar.items,
       index < items.count {
      tabBar.selectedItem = items[index]
    }
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let items = tabBar.items,
          let index = items.firstIndex(of: item),
          index < itemIds.count else { return }
    channel.invokeMethod("selected", arguments: itemIds[index])
  }
}

private func animeWitcherMenuImage(
  named name: String,
  tintColor: UIColor,
  pointSize: CGFloat = 18
) -> UIImage? {
  if name == "animewitcher.abc" || name == "animewitcher.zyx" {
    let font = UIFont.systemFont(ofSize: 15, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: tintColor,
    ]
    let text = (name == "animewitcher.abc" ? "ABC" : "ZYX") as NSString
    let measured = text.size(withAttributes: attributes)
    // Use one fixed canvas so ABC and ZYX have identical visual/icon bounds.
    let size = CGSize(width: 34, height: 18)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      let x = (size.width - measured.width) / 2
      let y = (size.height - measured.height) / 2
      text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }.withRenderingMode(.alwaysOriginal)
  }

  return UIImage(
    systemName: name,
    withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
  )?.withTintColor(tintColor, renderingMode: .alwaysOriginal)
}

private func animeWitcherConfigureGlassButton(
  _ button: UIButton,
  image: UIImage?,
  foreground: UIColor = .label
) {
  if #available(iOS 26.0, *) {
    var configuration = UIButton.Configuration.glass()
    configuration.image = image
    configuration.baseForegroundColor = foreground
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.cornerConfiguration = .capsule()
  } else if #available(iOS 15.0, *) {
    var configuration = UIButton.Configuration.plain()
    configuration.image = image
    configuration.baseForegroundColor = foreground
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.backgroundColor = .secondarySystemBackground
  } else {
    button.setImage(image, for: .normal)
    button.tintColor = foreground
    button.backgroundColor = .secondarySystemBackground
  }
}


private final class ApplePersistentGlassHeaderNativeController: NSObject {
  private let channel: FlutterMethodChannel
  private let hostViewProvider: () -> UIView?
  private let rootView = AnimeWitcherPassthroughView(frame: .zero)
  private let backButton = UIButton(type: .system)
  private let toolbar = AnimeWitcherPassthroughToolbar(frame: .zero)
  private var toolbarWidthConstraint: NSLayoutConstraint?
  private var toolbarTrailingConstraint: NSLayoutConstraint?
  private weak var installedHostView: UIView?
  private var lastArguments: Any?
  private var attachmentRetryScheduled = false
  private var didApplyInitialToolbarState = false
  private var currentActionItems: [UIBarButtonItem] = []
  private var currentActionKinds: [Int] = []
  private var toolbarVisible = false
  private var backVisible = false

  init(
    channel: FlutterMethodChannel,
    hostViewProvider: @escaping () -> UIView?
  ) {
    self.channel = channel
    self.hostViewProvider = hostViewProvider
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    rootView.clipsToBounds = false
    // Keep the persistent Liquid Glass chrome above Flutter route imagery and
    // any transient platform-view composition during push/pop transitions.
    rootView.layer.zPosition = 10_000

    backButton.translatesAutoresizingMaskIntoConstraints = false
    backButton.alpha = 0
    backButton.isHidden = true
    backButton.addTarget(self, action: #selector(backPressed), for: .touchUpInside)
    rootView.addSubview(backButton)

    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.isTranslucent = true
    toolbar.clipsToBounds = false
    toolbar.alpha = 0
    toolbar.isHidden = true
    if #unavailable(iOS 26.0) {
      toolbar.setBackgroundImage(UIImage(), forToolbarPosition: .any, barMetrics: .default)
      toolbar.setShadowImage(UIImage(), forToolbarPosition: .any)
      toolbar.backgroundColor = .clear
    }
    rootView.addSubview(toolbar)

    toolbarWidthConstraint = toolbar.widthAnchor.constraint(equalToConstant: 262)
    toolbarTrailingConstraint = toolbar.trailingAnchor.constraint(
      equalTo: rootView.safeAreaLayoutGuide.trailingAnchor,
      constant: -18
    )
    NSLayoutConstraint.activate([
      backButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
      backButton.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
      backButton.widthAnchor.constraint(equalToConstant: 46),
      backButton.heightAnchor.constraint(equalToConstant: 46),
      toolbarTrailingConstraint!,
      toolbar.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 46),
      toolbarWidthConstraint!,
    ])
  }

  func apply(arguments: Any?) {
    lastArguments = arguments
    guard ensureAttached() else { return }
    guard let values = arguments as? [String: Any] else { return }

    installedHostView?.bringSubviewToFront(rootView)
    if let insetNumber = values["toolbarTrailingInset"] as? NSNumber {
      let trailingConstant = -CGFloat(truncating: insetNumber)
      if toolbarTrailingConstraint?.constant != trailingConstant {
        UIView.performWithoutAnimation {
          toolbarTrailingConstraint?.constant = trailingConstant
          rootView.layoutIfNeeded()
        }
      }
    }
    let visible = values["visible"] as? Bool ?? false
    let showBack = visible && (values["showBack"] as? Bool ?? false)
    let backColor = animeWitcherUIColor(values["backColor"], fallback: .label)
    let backImage = UIImage(
      systemName: "chevron.left",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    )
    UIView.performWithoutAnimation {
      animeWitcherConfigureGlassButton(backButton, image: backImage, foreground: backColor)
      backButton.accessibilityLabel = values["backAccessibilityLabel"] as? String
      backButton.accessibilityTraits = .button
      backButton.layoutIfNeeded()
    }
    let instantVisibilityChanges = values["instantVisibilityChanges"] as? Bool ?? false
    setBackVisible(showBack, animated: !instantVisibilityChanges)

    let actions = visible ? (values["actions"] as? [[String: Any]] ?? []) : []
    let animateToolbarChanges = values["animateToolbarChanges"] as? Bool ?? true
    let hardCutToolbar = values["hardCutToolbar"] as? Bool ?? false
    if hardCutToolbar {
      toolbar.layer.removeAllAnimations()
      UIView.performWithoutAnimation {
        toolbar.setItems([], animated: false)
        toolbar.layoutIfNeeded()
      }
      currentActionItems = []
      currentActionKinds = []
      didApplyInitialToolbarState = false
    }
    if actions.isEmpty {
      setToolbarVisible(false, animated: !instantVisibilityChanges)
    } else {
      let wasVisible = toolbarVisible
      setToolbarVisible(true, animated: !instantVisibilityChanges)
      applyToolbar(
        actions: actions,
        animated: wasVisible && animateToolbarChanges
      )
    }
  }

  private func ensureAttached() -> Bool {
    guard let hostView = hostViewProvider() else {
      scheduleAttachmentRetry()
      return false
    }
    if installedHostView !== hostView || rootView.superview !== hostView {
      rootView.removeFromSuperview()
      rootView.translatesAutoresizingMaskIntoConstraints = false
      hostView.addSubview(rootView)
      NSLayoutConstraint.activate([
        rootView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
        rootView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
        rootView.topAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.topAnchor),
        rootView.heightAnchor.constraint(equalToConstant: 56),
      ])
      installedHostView = hostView
    }
    rootView.layer.zPosition = 10_000
    hostView.bringSubviewToFront(rootView)
    return true
  }

  private func scheduleAttachmentRetry() {
    guard !attachmentRetryScheduled else { return }
    attachmentRetryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self else { return }
      self.attachmentRetryScheduled = false
      if let arguments = self.lastArguments {
        self.apply(arguments: arguments)
      }
    }
  }

  private func setBackVisible(_ visible: Bool, animated: Bool = true) {
    guard backVisible != visible else { return }
    backVisible = visible
    backButton.layer.removeAllAnimations()
    if visible {
      backButton.isHidden = false
      backButton.alpha = 1
      return
    }
    if !animated {
      UIView.performWithoutAnimation {
        backButton.alpha = 0
        backButton.isHidden = true
      }
      return
    }
    UIView.animate(
      withDuration: 0.035,
      delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
    ) { [weak self] in
      self?.backButton.alpha = 0
    } completion: { [weak self] _ in
      guard let self, !self.backVisible else { return }
      self.backButton.isHidden = true
    }
  }

  private func setToolbarVisible(_ visible: Bool, animated: Bool = true) {
    guard toolbarVisible != visible else { return }
    toolbarVisible = visible
    // Stop intercepting touches as soon as hiding starts, including its fade.
    toolbar.isUserInteractionEnabled = visible
    toolbar.layer.removeAllAnimations()
    if visible {
      toolbar.isHidden = false
      toolbar.alpha = 1
      return
    }
    if !animated {
      UIView.performWithoutAnimation {
        toolbar.alpha = 0
        toolbar.isHidden = true
      }
      return
    }
    UIView.animate(
      withDuration: 0.035,
      delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
    ) { [weak self] in
      self?.toolbar.alpha = 0
    } completion: { [weak self] _ in
      guard let self, !self.toolbarVisible else { return }
      self.toolbar.isHidden = true
    }
  }

  private func actionHasMenu(_ action: [String: Any]) -> Bool {
    let menuItems = action["menuItems"] as? [[String: Any]] ?? []
    return !menuItems.isEmpty
  }

  private func actionTitle(_ action: [String: Any]) -> String? {
    guard let raw = action["title"] as? String else { return nil }
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private func actionTitleOnly(_ action: [String: Any]) -> Bool {
    action["titleOnly"] as? Bool == true && actionTitle(action) != nil
  }

  private func actionKind(_ action: [String: Any]) -> Int {
    (actionHasMenu(action) ? 1 : 0)
      | (actionTitle(action) != nil ? 2 : 0)
      | (actionTitleOnly(action) ? 4 : 0)
  }

  private func makeMenu(actionIndex: Int, action: [String: Any]) -> UIMenu? {
    guard #available(iOS 14.0, *) else { return nil }
    let selectedValue = action["selectedValue"] as? String
    let menuTint = animeWitcherUIColor(
      action["menuTintColor"],
      fallback: animeWitcherUIColor(action["color"], fallback: .label)
    )
    let rawItems = action["menuItems"] as? [[String: Any]] ?? []
    guard !rawItems.isEmpty else { return nil }
    let children: [UIAction] = rawItems.compactMap { [weak self] menuItem in
      guard let value = menuItem["value"] as? String,
            let label = menuItem["label"] as? String else { return nil }
      let isDestructive = menuItem["destructive"] as? Bool == true
      let image = (menuItem["systemImage"] as? String).flatMap { name -> UIImage? in
        if isDestructive { return UIImage(systemName: name) }
        return animeWitcherMenuImage(named: name, tintColor: menuTint)
      }
      var attributes: UIMenuElement.Attributes = []
      if isDestructive { attributes.insert(.destructive) }
      return UIAction(
        title: label,
        image: image,
        attributes: attributes,
        state: value == selectedValue ? .on : .off
      ) { _ in
        self?.channel.invokeMethod(
          "selected",
          arguments: ["index": actionIndex, "value": value]
        )
      }
    }
    return UIMenu(children: children)
  }

  private func configureActionItem(
    _ item: UIBarButtonItem,
    actionIndex: Int,
    action: [String: Any],
    actionCount: Int
  ) {
    let systemName = action["systemName"] as? String ?? "circle"
    let actionTint = animeWitcherUIColor(action["color"], fallback: .label)
    item.image = actionTitleOnly(action)
      ? nil
      : animeWitcherMenuImage(named: systemName, tintColor: actionTint, pointSize: 19)
    item.title = actionTitle(action)
    item.tag = actionIndex
    item.isEnabled = action["enabled"] as? Bool ?? true
    item.tintColor = actionTint
    item.accessibilityLabel = action["accessibilityLabel"] as? String
    if actionHasMenu(action), #available(iOS 14.0, *) {
      item.menu = makeMenu(actionIndex: actionIndex, action: action)
    } else if #available(iOS 14.0, *) {
      item.menu = nil
    }
    if #available(iOS 26.0, *) {
      item.sharesBackground = true
      item.hidesSharedBackground = false
      item.identifier = actionIndex == actionCount - 1
        ? "animewitcher.trailing.anchor"
        : "animewitcher.trailing.item.\(actionIndex)"
    }
  }

  private func desiredToolbarHostWidth(actions: [[String: Any]]) -> CGFloat {
    // The toolbar is a root-level native overlay above Flutter. Its transparent
    // host must be no wider than the controls it actually contains; otherwise
    // that invisible UIView sits on top of the search field and creates a dead
    // tap zone. Keep the same UIToolbar instance for Liquid Glass morphing, but
    // resize only its non-visible host geometry as the action set changes.
    var contentWidth: CGFloat = 32
    let titleFont = UIFont.systemFont(ofSize: 17, weight: .regular)

    for action in actions {
      if let title = actionTitle(action) {
        let measured = (title as NSString).size(withAttributes: [.font: titleFont]).width
        contentWidth += max(46, measured + 58)
      } else {
        contentWidth += 46
      }
    }

    return min(max(contentWidth, 78), 262)
  }

  private func updateToolbarHostWidth(actions: [[String: Any]]) {
    let width = desiredToolbarHostWidth(actions: actions)
    guard toolbarWidthConstraint?.constant != width else { return }
    // This only changes the transparent hit-test host. Do not animate it: the
    // visible Liquid Glass transition is still owned by UIToolbar.setItems.
    UIView.performWithoutAnimation {
      toolbarWidthConstraint?.constant = width
      rootView.layoutIfNeeded()
    }
  }

  private func makeActionItems(actions: [[String: Any]]) -> [UIBarButtonItem] {
    let actionItems: [UIBarButtonItem] = actions.enumerated().map { index, action in
      let systemName = action["systemName"] as? String ?? "circle"
      let actionTint = animeWitcherUIColor(action["color"], fallback: .label)
      let image = actionTitleOnly(action)
        ? nil
        : animeWitcherMenuImage(named: systemName, tintColor: actionTint, pointSize: 19)
      let item: UIBarButtonItem
      if #available(iOS 14.0, *), let menu = makeMenu(actionIndex: index, action: action) {
        item = UIBarButtonItem(
          title: actionTitle(action),
          image: image,
          primaryAction: nil,
          menu: menu
        )
      } else {
        item = UIBarButtonItem(
          image: image,
          style: .plain,
          target: self,
          action: #selector(itemPressed(_:))
        )
      }
      configureActionItem(
        item,
        actionIndex: index,
        action: action,
        actionCount: actions.count
      )
      return item
    }
    guard !actionItems.isEmpty else { return [] }
    return [UIBarButtonItem(systemItem: .flexibleSpace)] + actionItems
  }

  private func applyToolbar(actions: [[String: Any]], animated: Bool) {
    updateToolbarHostWidth(actions: actions)
    let actionKinds = actions.map(actionKind)
    if didApplyInitialToolbarState,
       currentActionItems.count == actions.count,
       currentActionKinds == actionKinds {
      UIView.performWithoutAnimation {
        for (index, action) in actions.enumerated() {
          configureActionItem(
            currentActionItems[index],
            actionIndex: index,
            action: action,
            actionCount: actions.count
          )
        }
        toolbar.layoutIfNeeded()
      }
      return
    }

    let items = makeActionItems(actions: actions)
    currentActionItems = items.dropFirst().map { $0 }
    currentActionKinds = actionKinds
    let shouldAnimate = didApplyInitialToolbarState && animated
    if shouldAnimate {
      toolbar.setItems(items, animated: true)
    } else {
      UIView.performWithoutAnimation {
        toolbar.setItems(items, animated: false)
        toolbar.layoutIfNeeded()
      }
    }
    didApplyInitialToolbarState = true
  }

  @objc private func backPressed() {
    guard backButton.isEnabled else { return }
    channel.invokeMethod("back", arguments: nil)
  }

  @objc private func itemPressed(_ sender: UIBarButtonItem) {
    guard sender.isEnabled else { return }
    channel.invokeMethod("pressed", arguments: sender.tag)
  }
}

private final class AppleNativeGlassButtonViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleNativeGlassButtonPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AppleNativeGlassButtonPlatformView: NSObject, FlutterPlatformView {
  private let rootView: UIView
  private let button = UIButton(type: .system)
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = UIView(frame: frame)
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/native_glass_button/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    button.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      button.topAnchor.constraint(equalTo: rootView.topAnchor),
      button.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
    button.addTarget(self, action: #selector(pressed), for: .touchUpInside)
    apply(arguments: args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.apply(arguments: call.arguments)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { rootView }

  private func apply(arguments: Any?) {
    guard let values = arguments as? [String: Any] else { return }
    let systemName = values["systemName"] as? String ?? "circle"
    let image = UIImage(
      systemName: systemName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
    )
    let foreground = animeWitcherUIColor(values["color"], fallback: .label)
    animeWitcherConfigureGlassButton(button, image: image, foreground: foreground)
    button.isEnabled = values["enabled"] as? Bool ?? true
    button.accessibilityLabel = values["accessibilityLabel"] as? String
    button.accessibilityTraits = .button
  }

  @objc private func pressed() {
    guard button.isEnabled else { return }
    channel.invokeMethod("pressed", arguments: nil)
  }
}


private final class AppleNativeSearchFieldViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleNativeSearchFieldPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AppleNativeSearchFieldPlatformView: NSObject, FlutterPlatformView, UITextFieldDelegate, UIGestureRecognizerDelegate {
  private let rootView: UIView
  private let effectView: UIVisualEffectView
  private let searchField = UISearchTextField(frame: .zero)
  private let channel: FlutterMethodChannel
  private var loadingIndicator: UIActivityIndicatorView?
  private var searchTapStartedFocused = false

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = UIView(frame: frame)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/native_search_field/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    rootView.clipsToBounds = false

    effectView.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerRadius = 21
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    rootView.addSubview(effectView)

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.backgroundColor = .clear
    searchField.borderStyle = .none
    searchField.clearButtonMode = .whileEditing
    searchField.returnKeyType = .search
    searchField.autocorrectionType = .no
    searchField.autocapitalizationType = .none
    searchField.delegate = self
    searchField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

    let searchTap = UITapGestureRecognizer(target: self, action: #selector(searchSurfaceTapped(_:)))
    searchTap.cancelsTouchesInView = false
    searchTap.delaysTouchesBegan = false
    searchTap.delaysTouchesEnded = false
    searchTap.delegate = self
    rootView.addGestureRecognizer(searchTap)

    effectView.contentView.addSubview(searchField)
    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      effectView.topAnchor.constraint(equalTo: rootView.topAnchor),
      effectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      searchField.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 14),
      searchField.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -12),
      searchField.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      searchField.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
    ])

    apply(arguments: args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.apply(arguments: call.arguments)
        result(true)
      case "focus":
        self.searchField.becomeFirstResponder()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { rootView }

  private func apply(arguments: Any?) {
    guard let values = arguments as? [String: Any] else { return }
    let text = values["text"] as? String ?? ""
    let placeholder = values["placeholder"] as? String ?? ""
    let tint = animeWitcherUIColor(values["tintColor"], fallback: .systemBlue)
    let textColor = animeWitcherUIColor(values["textColor"], fallback: .label)
    let placeholderColor = animeWitcherUIColor(
      values["placeholderColor"],
      fallback: .secondaryLabel
    )
    let rtl = values["rtl"] as? Bool ?? false
    let loading = values["loading"] as? Bool ?? false
    let height = (values["height"] as? NSNumber)?.doubleValue ?? 42

    if searchField.text != text { searchField.text = text }
    searchField.textColor = textColor
    searchField.tintColor = tint
    if let searchImageView = searchField.leftView as? UIImageView {
      searchImageView.tintColor = tint
    }
    searchField.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: placeholderColor]
    )
    // Keep the yellow magnifying glass on the physical left even in Arabic.
    searchField.semanticContentAttribute = .forceLeftToRight
    searchField.textAlignment = rtl ? .right : .left
    if #unavailable(iOS 26.0) {
      effectView.layer.cornerRadius = CGFloat(height / 2)
    }
    updateLoading(loading, tint: tint)
  }

  private func updateLoading(_ loading: Bool, tint: UIColor) {
    if loading {
      let indicator = loadingIndicator ?? UIActivityIndicatorView(style: .medium)
      indicator.color = tint
      indicator.startAnimating()
      loadingIndicator = indicator
      searchField.rightView = indicator
      searchField.rightViewMode = .always
      searchField.clearButtonMode = .never
    } else {
      loadingIndicator?.stopAnimating()
      searchField.rightView = nil
      searchField.rightViewMode = .never
      searchField.clearButtonMode = .whileEditing
    }
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    searchTapStartedFocused = searchField.isFirstResponder
    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // UISearchTextField owns internal selection/tap recognizers. Let the surface
    // recognizer observe the same tap so tapping anywhere in the glass can toggle
    // first-responder state without stealing cursor/selection behavior.
    return true
  }

  @objc private func searchSurfaceTapped(_ gestureRecognizer: UITapGestureRecognizer) {
    if searchTapStartedFocused {
      searchField.resignFirstResponder()
    } else {
      searchField.becomeFirstResponder()
    }
    searchTapStartedFocused = false
  }

  @objc private func textChanged() {
    channel.invokeMethod("changed", arguments: searchField.text ?? "")
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    // The Search key should behave like a committed search, not just emit the
    // query. Dismiss the native iOS keyboard first, then let Flutter submit the
    // final text to searchQueryProvider. The Flutter fallback already unfocuses
    // in _submitSearch; this mirrors that behavior for UISearchTextField.
    textField.resignFirstResponder()
    channel.invokeMethod("submitted", arguments: textField.text ?? "")
    return true
  }
}

private final class AppleNativeToolbarViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleNativeToolbarPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AnimeWitcherPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

private final class AnimeWitcherPassthroughToolbar: UIToolbar {
  private static let horizontalHitSlop: CGFloat = 22
  private static let verticalHitSlop: CGFloat = 10

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // Liquid Glass can render the trailing capsule outside UIToolbar's private
    // control bounds. Let the toolbar participate in hit testing across that
    // visible overflow; [hitTest] below still rejects transparent empty space.
    bounds.insetBy(
      dx: -Self.horizontalHitSlop,
      dy: -Self.verticalHitSlop
    ).contains(point)
  }

  private func descendantControls(in view: UIView) -> [UIControl] {
    view.subviews.flatMap { subview -> [UIControl] in
      let control = subview as? UIControl
      return (control.map { [$0] } ?? []) + descendantControls(in: subview)
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    // UIKit's default hitTest rejects hidden/disabled views, but the expanded
    // fallback below must honor the same gate. Otherwise an old hidden toolbar
    // can steal taps from Flutter's search/filter controls underneath it.
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
          self.point(inside: point, with: event) else { return nil }
    if let hit = super.hitTest(point, with: event) {
      var candidate: UIView? = hit
      while let view = candidate, view !== self {
        if view is UIControl { return hit }
        candidate = view.superview
      }
    }

    // iOS 26 can draw a shared Liquid Glass capsule and its symbol slightly
    // outside the private UIBarButtonItem control frame. Search the real
    // controls using an expanded hit rect, then route the touch to the closest
    // control so tapping the visible icon always triggers that exact action.
    let controls = descendantControls(in: self).filter {
      !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled && $0.isEnabled
    }
    let matches = controls.compactMap { control -> (UIControl, CGFloat)? in
      let localPoint = control.convert(point, from: self)
      let expandedBounds = control.bounds.insetBy(
        dx: -Self.horizontalHitSlop,
        dy: -Self.verticalHitSlop
      )
      guard expandedBounds.contains(localPoint) else { return nil }

      let dx = localPoint.x - control.bounds.midX
      let dy = localPoint.y - control.bounds.midY
      return (control, dx * dx + dy * dy)
    }
    guard let target = matches.min(by: { $0.1 < $1.1 })?.0 else {
      // Preserve passthrough behavior over the toolbar's flexible empty space.
      return nil
    }

    let localPoint = target.convert(point, from: self)
    return target.hitTest(localPoint, with: event) ?? target
  }
}

private final class AppleNativeToolbarPlatformView: NSObject, FlutterPlatformView {
  private let rootView: AnimeWitcherPassthroughView
  private let channel: FlutterMethodChannel
  private let toolbar: AnimeWitcherPassthroughToolbar
  private var didApplyInitialState = false
  private var currentActionItems: [UIBarButtonItem] = []
  private var currentActionKinds: [Int] = []
  private var pendingArguments: Any?
  private var pendingAnimated = false
  private var updateScheduled = false

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = AnimeWitcherPassthroughView(frame: frame)
    toolbar = AnimeWitcherPassthroughToolbar(frame: .zero)
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/native_toolbar/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    rootView.clipsToBounds = false

    // Use UIKit's real toolbar instead of drawing individual UIGlassEffect
    // droplets ourselves. On iOS 26 adjacent image bar-button items are grouped
    // by the system into one Liquid Glass capsule, and setItems(_:animated:)
    // provides the system transition when the group changes (for example,
    // details' three actions -> comments' single sort action).
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.isTranslucent = true
    toolbar.clipsToBounds = false
    rootView.addSubview(toolbar)
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      toolbar.topAnchor.constraint(equalTo: rootView.topAnchor),
      toolbar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])

    if #unavailable(iOS 26.0) {
      // Older iOS versions don't have the new floating toolbar treatment.
      // Keep the host visually transparent there; iOS 26 deliberately receives
      // no custom appearance so UIKit can render native Liquid Glass.
      toolbar.setBackgroundImage(UIImage(), forToolbarPosition: .any, barMetrics: .default)
      toolbar.setShadowImage(UIImage(), forToolbarPosition: .any)
      toolbar.backgroundColor = .clear
    }

    apply(arguments: args, animated: false)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.scheduleApply(arguments: call.arguments, animated: true)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { rootView }

  private func scheduleApply(arguments: Any?, animated: Bool) {
    pendingArguments = arguments
    pendingAnimated = pendingAnimated || animated
    guard !updateScheduled else { return }
    updateScheduled = true

    // Flutter can publish several header states in the same frame while a route
    // is pushing and async detail state is settling. Applying each one makes
    // UIToolbar start overlapping Liquid Glass transitions. Coalesce them to the
    // latest state for this run-loop turn, then let UIKit animate only once.
    // Start the native structural morph on the next display interval rather
    // than competing with Flutter's first route-transition frame. Updates that
    // arrive during that interval are still coalesced into the latest state.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
      guard let self else { return }
      self.updateScheduled = false
      let arguments = self.pendingArguments
      let animated = self.pendingAnimated
      self.pendingArguments = nil
      self.pendingAnimated = false
      self.apply(arguments: arguments, animated: animated)
    }
  }

  private func makeMenu(
    actionIndex: Int,
    action: [String: Any]
  ) -> UIMenu? {
    guard #available(iOS 14.0, *) else { return nil }
    let selectedValue = action["selectedValue"] as? String
    let menuTint = animeWitcherUIColor(
      action["menuTintColor"],
      fallback: animeWitcherUIColor(action["color"], fallback: .label)
    )
    let rawItems = action["menuItems"] as? [[String: Any]] ?? []
    guard !rawItems.isEmpty else { return nil }

    let children: [UIAction] = rawItems.compactMap { [weak self] menuItem in
      guard let value = menuItem["value"] as? String,
            let label = menuItem["label"] as? String else { return nil }
      let isDestructive = menuItem["destructive"] as? Bool == true
      let image = (menuItem["systemImage"] as? String).flatMap { name -> UIImage? in
        if isDestructive { return UIImage(systemName: name) }
        return animeWitcherMenuImage(named: name, tintColor: menuTint)
      }
      var attributes: UIMenuElement.Attributes = []
      if isDestructive { attributes.insert(.destructive) }
      return UIAction(
        title: label,
        image: image,
        attributes: attributes,
        state: value == selectedValue ? .on : .off
      ) { _ in
        self?.channel.invokeMethod(
          "selected",
          arguments: ["index": actionIndex, "value": value]
        )
      }
    }
    return UIMenu(children: children)
  }

  private func actionHasMenu(_ action: [String: Any]) -> Bool {
    let menuItems = action["menuItems"] as? [[String: Any]] ?? []
    return !menuItems.isEmpty
  }

  private func actionTitle(_ action: [String: Any]) -> String? {
    guard let raw = action["title"] as? String else { return nil }
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private func actionKind(_ action: [String: Any]) -> Int {
    (actionHasMenu(action) ? 1 : 0) | (actionTitle(action) != nil ? 2 : 0)
  }

  private func configureActionItem(
    _ item: UIBarButtonItem,
    actionIndex: Int,
    action: [String: Any],
    actionCount: Int
  ) {
    let systemName = action["systemName"] as? String ?? "circle"
    let actionTint = animeWitcherUIColor(action["color"], fallback: .label)
    item.image = animeWitcherMenuImage(named: systemName, tintColor: actionTint, pointSize: 19)
    item.title = actionTitle(action)
    item.tag = actionIndex
    item.isEnabled = action["enabled"] as? Bool ?? true
    item.tintColor = actionTint
    item.accessibilityLabel = action["accessibilityLabel"] as? String
    if actionHasMenu(action), #available(iOS 14.0, *) {
      item.menu = makeMenu(actionIndex: actionIndex, action: action)
    }
    if #available(iOS 26.0, *) {
      item.sharesBackground = true
      item.hidesSharedBackground = false
      item.identifier = actionIndex == actionCount - 1
        ? "animewitcher.trailing.anchor"
        : "animewitcher.trailing.item.\(actionIndex)"
    }
  }

  private func makeActionItems(actions: [[String: Any]]) -> [UIBarButtonItem] {
    let actionItems: [UIBarButtonItem] = actions.enumerated().map { index, action in
      let systemName = action["systemName"] as? String ?? "circle"
      let actionTint = animeWitcherUIColor(action["color"], fallback: .label)
      let image = animeWitcherMenuImage(named: systemName, tintColor: actionTint, pointSize: 19)
      let item: UIBarButtonItem

      if #available(iOS 14.0, *), let menu = makeMenu(actionIndex: index, action: action) {
        // A UIBarButtonItem-owned UIMenu is the native tap-to-open menu path.
        // A library category can also carry a title while remaining the same
        // system toolbar item that morphs into the details action group.
        item = UIBarButtonItem(
          title: actionTitle(action),
          image: image,
          primaryAction: nil,
          menu: menu
        )
      } else {
        item = UIBarButtonItem(
          image: image,
          style: .plain,
          target: self,
          action: #selector(itemPressed(_:))
        )
      }

      configureActionItem(
        item,
        actionIndex: index,
        action: action,
        actionCount: actions.count
      )
      return item
    }

    guard !actionItems.isEmpty else { return [] }
    // A single flexible spacer keeps both the 3-item capsule and the 1-item
    // sort button pinned to the same trailing edge. The image items remain
    // adjacent, so UIKit groups them into one Liquid Glass background.
    return [UIBarButtonItem(systemItem: .flexibleSpace)] + actionItems
  }

  private func apply(arguments: Any?, animated: Bool) {
    guard let values = arguments as? [String: Any] else { return }
    let actions = values["actions"] as? [[String: Any]] ?? []
    let actionKinds = actions.map(actionKind)

    // A favorite/bookmark state change only changes an item's image/tint/menu
    // state. Replacing the entire toolbar in that case makes UIKit run its
    // setItems transition again, which causes the Liquid Glass capsule to
    // dissolve/stretch even though its geometry never changed. Keep the same
    // UIBarButtonItem instances and update them in place instead.
    if didApplyInitialState,
       currentActionItems.count == actions.count,
       currentActionKinds == actionKinds {
      UIView.performWithoutAnimation {
        for (index, action) in actions.enumerated() {
          configureActionItem(
            currentActionItems[index],
            actionIndex: index,
            action: action,
            actionCount: actions.count
          )
        }
        toolbar.layoutIfNeeded()
      }
      return
    }

    let items = makeActionItems(actions: actions)
    currentActionItems = items.dropFirst().map { $0 }
    currentActionKinds = actionKinds
    let shouldAnimate = didApplyInitialState && animated

    // Reserve setItems(animated:) for real structural transitions such as the
    // details 3-button group morphing into the single comments-sort control.
    toolbar.setItems(items, animated: shouldAnimate)
    didApplyInitialState = true
  }

  @objc private func itemPressed(_ sender: UIBarButtonItem) {
    guard sender.isEnabled else { return }
    channel.invokeMethod("pressed", arguments: sender.tag)
  }
}

private final class AppleNativeMenuButtonViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleNativeMenuButtonPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AnimeWitcherMenuAwareButton: UIButton {
  var onMenuWillShow: (() -> Void)?
  var onMenuWillHide: (() -> Void)?

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    onMenuWillShow?()
    super.contextMenuInteraction(
      interaction,
      willDisplayMenuFor: configuration,
      animator: animator
    )
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    onMenuWillHide?()
    super.contextMenuInteraction(
      interaction,
      willEndFor: configuration,
      animator: animator
    )
  }
}

private final class AppleNativeMenuButtonPlatformView: NSObject, FlutterPlatformView {
  private let rootView: UIView
  private let button = AnimeWitcherMenuAwareButton(type: .system)
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = UIView(frame: frame)
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/native_menu_button/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    button.translatesAutoresizingMaskIntoConstraints = false
    button.onMenuWillShow = { [weak self] in
      self?.channel.invokeMethod("menuOpened", arguments: nil)
    }
    button.onMenuWillHide = { [weak self] in
      self?.channel.invokeMethod("menuClosed", arguments: nil)
    }
    rootView.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      button.topAnchor.constraint(equalTo: rootView.topAnchor),
      button.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
    apply(arguments: args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.apply(arguments: call.arguments)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { rootView }

  private func apply(arguments: Any?) {
    guard let values = arguments as? [String: Any] else { return }
    let invisibleAnchor = values["invisibleAnchor"] as? Bool ?? false
    let systemName = values["systemImage"] as? String ?? "arrow.up.arrow.down"
    let tintColor = animeWitcherUIColor(values["tintColor"], fallback: .label)
    let cornerRadius = (values["cornerRadius"] as? NSNumber)?.doubleValue
    let showsMenuIndicator = values["showsMenuIndicator"] as? Bool ?? false
    let title = (values["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    if invisibleAnchor {
      if #available(iOS 15.0, *) {
        var configuration = UIButton.Configuration.plain()
        configuration.baseBackgroundColor = .clear
        configuration.background.backgroundColor = .clear
        configuration.contentInsets = .zero
        configuration.image = nil
        configuration.title = nil
        button.configuration = configuration
      } else {
        button.setImage(nil, for: .normal)
        button.setTitle(nil, for: .normal)
      }
      button.backgroundColor = .clear
      button.tintColor = tintColor
    } else {
      let image = animeWitcherMenuImage(named: systemName, tintColor: tintColor)
      animeWitcherConfigureGlassButton(button, image: image, foreground: tintColor)
      button.tintColor = tintColor
      if #available(iOS 15.0, *), var configuration = button.configuration {
        configuration.title = (title?.isEmpty == false) ? title : nil
        configuration.imagePadding = (title?.isEmpty == false) ? 8 : 0
        configuration.contentInsets = (title?.isEmpty == false)
          ? NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
          : .zero
        if #available(iOS 26.0, *) {
          configuration.indicator = showsMenuIndicator ? .popup : .none
        }
        button.configuration = configuration
      } else {
        button.setTitle((title?.isEmpty == false) ? title : nil, for: .normal)
      }
      if #available(iOS 26.0, *), let cornerRadius {
        button.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
      }
    }
    button.semanticContentAttribute = (values["isRtl"] as? Bool == true)
      ? .forceRightToLeft
      : .forceLeftToRight
    button.isEnabled = values["enabled"] as? Bool ?? true
    button.accessibilityLabel = values["accessibilityLabel"] as? String
    button.accessibilityTraits = .button

    let isRtl = values["isRtl"] as? Bool == true
    let selectedValue = values["selectedValue"] as? String
    let items = values["items"] as? [[String: Any]] ?? []
    let actions: [UIAction] = items.compactMap { item in
      guard let value = item["value"] as? String,
            let label = item["label"] as? String else { return nil }
      let systemImage = item["systemImage"] as? String
      let isDestructive = item["destructive"] as? Bool == true
      let actionImage = systemImage.flatMap { name -> UIImage? in
        if isDestructive {
          return UIImage(systemName: name)
        }
        return animeWitcherMenuImage(named: name, tintColor: tintColor)
      }
      var attributes: UIMenuElement.Attributes = []
      if isDestructive {
        attributes.insert(.destructive)
      }
      return UIAction(
        title: animeWitcherMenuTitle(label, isRtl: isRtl),
        image: actionImage,
        attributes: attributes,
        state: value == selectedValue ? .on : .off
      ) { [weak self] _ in
        self?.channel.invokeMethod("selected", arguments: value)
      }
    }
    // Deferred element reliably signals presentation; willEnd covers dismiss.
    let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
      self?.channel.invokeMethod("menuOpened", arguments: nil)
      completion(actions)
    }
    button.menu = UIMenu(children: [deferred])
    button.showsMenuAsPrimaryAction = !actions.isEmpty
    if #available(iOS 16.0, *) {
      button.preferredMenuElementOrder = .fixed
    }
  }
}

private final class AppleLiquidGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleLiquidGlassPlatformView(frame: frame, arguments: args)
  }
}

private final class AppleLiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let rootView: UIView

  init(frame: CGRect, arguments args: Any?) {
    let parameters = args as? [String: Any]
    let cornerRadius = (parameters?["cornerRadius"] as? NSNumber)?.doubleValue ?? 999
    let requestedStyle = parameters?["style"] as? String ?? "regular"
    let interactive = parameters?["interactive"] as? Bool ?? false

    rootView = UIView(frame: frame)
    rootView.backgroundColor = .clear
    rootView.isUserInteractionEnabled = false

    let effectView = UIVisualEffectView(frame: rootView.bounds)
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.isUserInteractionEnabled = false

    if #available(iOS 26.0, *) {
      let style: UIGlassEffect.Style = requestedStyle == "clear" ? .clear : .regular
      let glassEffect = UIGlassEffect(style: style)
      // This platform view is background-only, so don't advertise native
      // interactivity that Flutter would intercept above it.
      glassEffect.isInteractive = false
      effectView.effect = glassEffect
      effectView.cornerConfiguration = cornerRadius >= 900
        ? .capsule()
        : .corners(radius: .fixed(cornerRadius))
    } else {
      rootView.clipsToBounds = true
      rootView.layer.cornerRadius = cornerRadius
      effectView.effect = UIBlurEffect(style: .systemMaterial)
    }

    rootView.addSubview(effectView)
    super.init()
  }

  func view() -> UIView {
    rootView
  }
}



private final class AppleSearchGlassActionsViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AppleSearchGlassActionsPlatformView(
      frame: frame,
      viewId: viewId,
      messenger: messenger,
      arguments: args
    )
  }
}

private final class AppleSearchActionsHitView: UIView {
  weak var sortButton: UIControl?
  weak var filterButton: UIControl?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let hit = super.hitTest(point, with: event), hit !== self {
      return hit
    }
    guard bounds.contains(point) else { return nil }

    // UIKit can draw iOS 26 Liquid Glass outside the private UIButton content
    // frame. Treat each half of the platform view as the hit target for its
    // visible action so taps on the filter glass never land in an inert gap.
    let target = point.x >= bounds.midX ? filterButton : sortButton
    guard let target,
          !target.isHidden,
          target.alpha > 0.01,
          target.isUserInteractionEnabled,
          target.isEnabled else {
      return nil
    }
    let localPoint = target.convert(point, from: self)
    return target.hitTest(localPoint, with: event) ?? target
  }
}

private final class AppleSearchGlassActionsPlatformView: NSObject, FlutterPlatformView {
  private let rootView: AppleSearchActionsHitView
  private let channel: FlutterMethodChannel
  private let sortButton = UIButton(type: .system)
  private let filterButton = UIButton(type: .system)
  private let filterBadge = UILabel()
  private var filterLoading = false
  private var filterCount = 0

  init(
    frame: CGRect,
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    arguments args: Any?
  ) {
    rootView = AppleSearchActionsHitView(frame: frame)
    channel = FlutterMethodChannel(
      name: "com.animewitcher.app/search_glass_actions/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    rootView.backgroundColor = .clear
    rootView.isOpaque = false
    rootView.sortButton = sortButton
    rootView.filterButton = filterButton
    configureControls(arguments: args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "update":
        self.apply(arguments: call.arguments)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { rootView }

  private func configureControls(arguments: Any?) {
    let sortImage = UIImage(
      systemName: "arrow.up.arrow.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    let filterImage = UIImage(
      systemName: "slider.horizontal.3",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    animeWitcherConfigureGlassButton(sortButton, image: sortImage)
    animeWitcherConfigureGlassButton(filterButton, image: filterImage)
    filterButton.addTarget(self, action: #selector(filterPressed), for: .touchUpInside)

    filterBadge.textAlignment = .center
    filterBadge.font = .systemFont(ofSize: 9, weight: .bold)
    filterBadge.textColor = .white
    filterBadge.backgroundColor = .label
    filterBadge.layer.cornerRadius = 8
    filterBadge.clipsToBounds = true
    filterBadge.isHidden = true
    filterBadge.isAccessibilityElement = false

    let stack = UIStackView(arrangedSubviews: [sortButton, filterButton])
    stack.axis = .horizontal
    stack.spacing = 8
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: rootView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      sortButton.widthAnchor.constraint(equalTo: sortButton.heightAnchor),
      filterButton.widthAnchor.constraint(equalTo: filterButton.heightAnchor),
      sortButton.heightAnchor.constraint(equalTo: rootView.heightAnchor),
      filterButton.heightAnchor.constraint(equalTo: rootView.heightAnchor),
    ])

    filterButton.addSubview(filterBadge)
    filterBadge.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      filterBadge.topAnchor.constraint(equalTo: filterButton.topAnchor, constant: 1),
      filterBadge.trailingAnchor.constraint(equalTo: filterButton.trailingAnchor, constant: -1),
      filterBadge.heightAnchor.constraint(equalToConstant: 16),
      filterBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
    ])

    apply(arguments: arguments)
  }

  private func apply(arguments: Any?) {
    guard let values = arguments as? [String: Any] else { return }
    filterCount = (values["filterCount"] as? NSNumber)?.intValue ?? 0
    filterLoading = values["filterLoading"] as? Bool ?? false
    let tintColor = animeWitcherUIColor(values["tintColor"], fallback: .label)
    filterButton.isEnabled = !filterLoading
    filterBadge.text = filterCount > 99 ? "99+" : "\(filterCount)"
    filterBadge.backgroundColor = tintColor
    filterBadge.isHidden = filterCount <= 0 || filterLoading
    sortButton.accessibilityLabel = values["sortAccessibilityLabel"] as? String
    filterButton.accessibilityLabel = values["filterAccessibilityLabel"] as? String
    sortButton.tintColor = tintColor
    filterButton.tintColor = tintColor

    if #available(iOS 15.0, *) {
      if var sortConfiguration = sortButton.configuration {
        sortConfiguration.baseForegroundColor = tintColor
        sortButton.configuration = sortConfiguration
      }
      if var filterConfiguration = filterButton.configuration {
        filterConfiguration.showsActivityIndicator = filterLoading
        filterConfiguration.image = filterLoading
          ? nil
          : UIImage(
              systemName: "slider.horizontal.3",
              withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            )
        filterConfiguration.baseForegroundColor = tintColor
        filterButton.configuration = filterConfiguration
      }
    }

    let selectedValue = values["sortValue"] as? String
    let isRtl = values["isArabic"] as? Bool == true
    let items = values["sortItems"] as? [[String: Any]] ?? []
    let actions: [UIAction] = items.compactMap { item in
      guard let value = item["value"] as? String,
            let label = item["label"] as? String else { return nil }
      let symbolName = item["systemImage"] as? String
      let image = symbolName.flatMap { name in
        animeWitcherMenuImage(named: name, tintColor: tintColor)
      }
      return UIAction(
        title: animeWitcherMenuTitle(label, isRtl: isRtl),
        image: image,
        state: value == selectedValue ? .on : .off
      ) { [weak self] _ in
        self?.channel.invokeMethod("sortSelected", arguments: value)
      }
    }
    sortButton.menu = UIMenu(children: actions)
    sortButton.showsMenuAsPrimaryAction = !actions.isEmpty
    if #available(iOS 16.0, *) {
      sortButton.preferredMenuElementOrder = .fixed
    }
  }

  @objc private func filterPressed() {
    guard !filterLoading else { return }
    channel.invokeMethod("filterPressed", arguments: nil)
  }
}

private func animeWitcherTopViewController() -> UIViewController? {
  let scene = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .first { $0.activationState == .foregroundActive }
  let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    ?? scene?.windows.first?.rootViewController

  func top(_ controller: UIViewController?) -> UIViewController? {
    guard let controller else { return nil }
    if let presented = controller.presentedViewController { return top(presented) }
    if let navigation = controller as? UINavigationController { return top(navigation.visibleViewController) }
    if let tab = controller as? UITabBarController { return top(tab.selectedViewController) }
    return controller
  }
  return top(root)
}

@available(iOS 26.0, *)
private struct AppleSearchSortItem: Identifiable {
  let id: String
  let label: String
}

@available(iOS 26.0, *)
private struct AppleSearchSortOverlay: View {
  let items: [AppleSearchSortItem]
  let isArabic: Bool
  let tintColor: Color
  let onCancel: () -> Void
  let onApply: (String) -> Void
  @State private var selected: String

  init(
    items: [AppleSearchSortItem],
    initialValue: String,
    isArabic: Bool,
    tintColor: Color,
    onCancel: @escaping () -> Void,
    onApply: @escaping (String) -> Void
  ) {
    self.items = items
    self.isArabic = isArabic
    self.tintColor = tintColor
    self.onCancel = onCancel
    self.onApply = onApply
    let defaultValue = items.first?.id ?? ""
    _selected = State(initialValue: items.contains(where: { $0.id == initialValue }) ? initialValue : defaultValue)
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.16).ignoresSafeArea()
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.tint)
          Text(isArabic ? "الترتيب حسب" : "Sort by")
            .font(.title2.weight(.bold))
          Spacer()
          Button(action: onCancel) {
            Image(systemName: "xmark")
              .font(.system(size: 18, weight: .semibold))
              .frame(width: 36, height: 36)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)

        Divider()

        ScrollView {
          VStack(spacing: 4) {
            ForEach(items) { item in
              Button {
                selected = item.id
              } label: {
                HStack(spacing: 14) {
                  Text(item.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                  Spacer()
                  Image(systemName: selected == item.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected == item.id ? tintColor : Color.secondary)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 8)
        }
        .frame(maxHeight: 390)

        Divider()

        HStack(spacing: 12) {
          Button(isArabic ? "إلغاء" : "Cancel", action: onCancel)
            .buttonStyle(.plain)
          Spacer()
          Button(isArabic ? "تطبيق" : "Apply") {
            onApply(selected)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }
        .padding(16)
      }
      .frame(maxWidth: 520)
      .glassEffect(.regular, in: .rect(cornerRadius: 30))
      .padding(.horizontal, 18)
    }
    .tint(tintColor)
    .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
  }
}

@available(iOS 26.0, *)
private enum AppleSearchFilterTab: String, CaseIterable, Identifiable {
  case genres, year, age, type, status
  var id: String { rawValue }
}

private func animeWitcherStrings(_ value: Any?) -> [String] {
  if let strings = value as? [String] { return strings }
  if let values = value as? [Any] { return values.compactMap { $0 as? String } }
  return []
}

@available(iOS 26.0, *)
private struct AppleSearchFilterOverlay: View {
  let statuses: [String]
  let types: [String]
  let ageRatings: [String]
  let years: [String]
  let seasons: [String]
  let genres: [String]
  let isArabic: Bool
  let tintColor: Color
  let onCancel: () -> Void
  let onApply: ([String: Any]) -> Void

  @State private var tab: AppleSearchFilterTab = .genres
  @State private var selectedStatuses: Set<String>
  @State private var selectedTypes: Set<String>
  @State private var selectedAgeRatings: Set<String>
  @State private var selectedYears: Set<String>
  @State private var selectedSeasons: Set<String>
  @State private var selectedGenres: Set<String>

  init(
    options: [String: Any],
    initialValue: [String: Any],
    isArabic: Bool,
    tintColor: Color,
    onCancel: @escaping () -> Void,
    onApply: @escaping ([String: Any]) -> Void
  ) {
    statuses = animeWitcherStrings(options["statuses"])
    types = animeWitcherStrings(options["types"])
    ageRatings = animeWitcherStrings(options["ageRatings"])
    years = animeWitcherStrings(options["years"])
    seasons = animeWitcherStrings(options["seasons"])
    genres = animeWitcherStrings(options["genres"])
    self.isArabic = isArabic
    self.tintColor = tintColor
    self.onCancel = onCancel
    self.onApply = onApply
    _selectedStatuses = State(initialValue: Set(animeWitcherStrings(initialValue["statuses"])))
    _selectedTypes = State(initialValue: Set(animeWitcherStrings(initialValue["types"])))
    _selectedAgeRatings = State(initialValue: Set(animeWitcherStrings(initialValue["ageRatings"])))
    _selectedYears = State(initialValue: Set(animeWitcherStrings(initialValue["years"])))
    _selectedSeasons = State(initialValue: Set(animeWitcherStrings(initialValue["seasons"])))
    _selectedGenres = State(initialValue: Set(animeWitcherStrings(initialValue["genres"])))
  }

  private var seasonRequiresYear: Bool {
    !selectedSeasons.isEmpty && selectedYears.isEmpty
  }

  private var selectedCount: Int {
    selectedStatuses.count + selectedTypes.count + selectedAgeRatings.count +
      selectedYears.count + selectedSeasons.count + selectedGenres.count
  }

  private func tabLabel(_ value: AppleSearchFilterTab) -> String {
    switch value {
    case .genres: return isArabic ? "التصنيفات" : "Genres"
    case .year: return isArabic ? "السنة" : "Year"
    case .age: return isArabic ? "العمر" : "Age"
    case .type: return isArabic ? "النوع" : "Type"
    case .status: return isArabic ? "الحالة" : "Status"
    }
  }

  private func tabIcon(_ value: AppleSearchFilterTab) -> String {
    switch value {
    case .genres: return "tag"
    case .year: return "calendar"
    case .age: return "shield"
    case .type: return "square.grid.2x2"
    case .status: return "dot.radiowaves.left.and.right"
    }
  }

  private func clearAll() {
    selectedStatuses.removeAll()
    selectedTypes.removeAll()
    selectedAgeRatings.removeAll()
    selectedYears.removeAll()
    selectedSeasons.removeAll()
    selectedGenres.removeAll()
  }

  private func payload() -> [String: Any] {
    [
      "statuses": Array(selectedStatuses),
      "types": Array(selectedTypes),
      "ageRatings": Array(selectedAgeRatings),
      "years": Array(selectedYears),
      "seasons": Array(selectedSeasons),
      "genres": Array(selectedGenres),
    ]
  }

  private func toggled(_ set: Set<String>, value: String) -> Set<String> {
    var copy = set
    if copy.contains(value) { copy.remove(value) } else { copy.insert(value) }
    return copy
  }

  @ViewBuilder
  private func choiceGrid(
    values: [String],
    selected: Set<String>,
    columns: Int,
    onToggle: @escaping (String) -> Void
  ) -> some View {
    let grid = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
    LazyVGrid(columns: grid, spacing: 10) {
      ForEach(values, id: \.self) { value in
        let isSelected = selected.contains(value)
        Button {
          onToggle(value)
        } label: {
          Text(value)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 8)
            .background(
              isSelected ? tintColor : Color.white.opacity(0.10),
              in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private var seasonYearGrid: some View {
    VStack(alignment: .leading, spacing: 18) {
      if !seasons.isEmpty {
        choiceGrid(
          values: seasons,
          selected: selectedSeasons,
          columns: 4,
          onToggle: { value in
            if selectedSeasons.contains(value) {
              selectedSeasons.removeAll()
            } else {
              selectedSeasons = [value]
            }
          }
        )
      }
      choiceGrid(
        values: years,
        selected: selectedYears,
        columns: 4,
        onToggle: { value in selectedYears = toggled(selectedYears, value: value) }
      )
    }
  }

  @ViewBuilder
  private var currentFilterContent: some View {
    switch tab {
    case .genres:
      choiceGrid(values: genres, selected: selectedGenres, columns: 3) {
        selectedGenres = toggled(selectedGenres, value: $0)
      }
    case .year:
      seasonYearGrid
    case .age:
      choiceGrid(values: ageRatings, selected: selectedAgeRatings, columns: 2) {
        selectedAgeRatings = toggled(selectedAgeRatings, value: $0)
      }
    case .type:
      choiceGrid(values: types, selected: selectedTypes, columns: 2) {
        selectedTypes = toggled(selectedTypes, value: $0)
      }
    case .status:
      choiceGrid(values: statuses, selected: selectedStatuses, columns: 2) {
        selectedStatuses = toggled(selectedStatuses, value: $0)
      }
    }
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.46).ignoresSafeArea()
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 21, weight: .semibold))
              .foregroundStyle(.tint)
            Text(isArabic ? "فلاتر البحث" : "Search filters")
              .font(.title2.weight(.bold))
            if selectedCount > 0 {
              Text("\(selectedCount)")
                .font(.caption.bold())
                .foregroundStyle(.tint)
            }
            Spacer()
            Button(action: onCancel) {
              Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 15)

          Divider()

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
              ForEach(AppleSearchFilterTab.allCases) { item in
                Button {
                  tab = item
                } label: {
                  HStack(spacing: 6) {
                    Image(systemName: tabIcon(item))
                    Text(tabLabel(item))
                      .font(.subheadline.weight(.semibold))
                  }
                  .foregroundStyle(tab == item ? tintColor : Color.secondary)
                  .padding(.horizontal, 10)
                  .frame(height: 44)
                  .overlay(alignment: .bottom) {
                    if tab == item {
                      Capsule().fill(tintColor).frame(height: 3)
                    }
                  }
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 14)
          }

          Divider()

          ScrollView {
            currentFilterContent
              .padding(16)
          }
          .frame(maxHeight: .infinity)

          Divider()

          VStack(spacing: 10) {
            if seasonRequiresYear {
              Label(
                isArabic ? "اختر سنة مع الموسم" : "Choose a year with the season",
                systemImage: "info.circle"
              )
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tint)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
              Button {
                clearAll()
              } label: {
                Label(isArabic ? "مسح الكل" : "Clear all", systemImage: "arrow.counterclockwise")
              }
              .buttonStyle(.plain)
              .disabled(selectedCount == 0)

              Spacer()

              Button(isArabic ? "تطبيق" : "Apply") {
                onApply(payload())
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(seasonRequiresYear)
            }
          }
          .padding(16)
        }
        .frame(
          width: min(geometry.size.width - 32, 560),
          height: min(geometry.size.height * 0.82, 720)
        )
        .background(
          Color.black.opacity(0.34),
          in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .tint(tintColor)
    .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
  }
}

@available(iOS 26.0, *)
private func presentAppleSearchSort(
  from presenter: UIViewController,
  arguments: [String: Any],
  result: @escaping FlutterResult
) {
  let rawItems = arguments["items"] as? [[String: Any]] ?? []
  let items = rawItems.compactMap { raw -> AppleSearchSortItem? in
    guard let value = raw["value"] as? String,
          let label = raw["label"] as? String else { return nil }
    return AppleSearchSortItem(id: value, label: label)
  }
  let initialValue = arguments["initialValue"] as? String ?? ""
  let isArabic = arguments["isArabic"] as? Bool ?? false
  let tintColor = Color(
    uiColor: animeWitcherUIColor(arguments["tintColor"], fallback: .systemBlue)
  )
  var hostingController: UIHostingController<AppleSearchSortOverlay>?
  let overlay = AppleSearchSortOverlay(
    items: items,
    initialValue: initialValue,
    isArabic: isArabic,
    tintColor: tintColor,
    onCancel: {
      hostingController?.dismiss(animated: true) { result(nil) }
    },
    onApply: { value in
      hostingController?.dismiss(animated: true) { result(value) }
    }
  )
  let host = UIHostingController(rootView: overlay)
  hostingController = host
  host.view.backgroundColor = .clear
  host.modalPresentationStyle = .overFullScreen
  host.modalTransitionStyle = .crossDissolve
  presenter.present(host, animated: true)
}

@available(iOS 26.0, *)
private func presentAppleSearchFilters(
  from presenter: UIViewController,
  arguments: [String: Any],
  result: @escaping FlutterResult
) {
  let options = arguments["options"] as? [String: Any] ?? [:]
  let initialValue = arguments["initialValue"] as? [String: Any] ?? [:]
  let isArabic = arguments["isArabic"] as? Bool ?? false
  let tintColor = Color(
    uiColor: animeWitcherUIColor(arguments["tintColor"], fallback: .systemBlue)
  )
  var hostingController: UIHostingController<AppleSearchFilterOverlay>?
  let overlay = AppleSearchFilterOverlay(
    options: options,
    initialValue: initialValue,
    isArabic: isArabic,
    tintColor: tintColor,
    onCancel: {
      hostingController?.dismiss(animated: true) { result(nil) }
    },
    onApply: { value in
      hostingController?.dismiss(animated: true) { result(value) }
    }
  )
  let host = UIHostingController(rootView: overlay)
  hostingController = host
  host.view.backgroundColor = .clear
  host.modalPresentationStyle = .overFullScreen
  host.modalTransitionStyle = .crossDissolve
  presenter.present(host, animated: true)
}
