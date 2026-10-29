import Cocoa
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

let kakaoBundleID = "com.kakao.KakaoTalkMac"

// MARK: - AX helpers

func axAttr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

/// 화면 좌상단 기준(AX 좌표) 프레임
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

// MARK: - 확인용 파일 쓰기 (개발용 빌드 전용)

#if DEBUG
/// 확인용 출력은 본인만 읽을 수 있게(0600) 쓴다
func writePrivate(_ data: Data, to path: String) {
    FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
}

/// 창 구조를 남긴다. 대화 상대 이름이나 메시지가 섞이지 않게 제목, 설명, 값은 적지 않고 역할, 식별자, 위치만 적는다.
func dumpTree(to path: String) {
    var out = "trusted: \(AXIsProcessTrusted())\n"
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundleID).first {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        func walk(_ e: AXUIElement, _ depth: Int) {
            let role = axAttr(e, kAXRoleAttribute) as? String ?? "?"
            let sub = axAttr(e, kAXSubroleAttribute) as? String ?? ""
            let id = axAttr(e, kAXIdentifierAttribute) as? String ?? ""
            let kids = axChildren(e)
            let f = axFrame(e).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? ""
            out += String(repeating: "  ", count: depth) + "\(role) \(sub) id=\(id) \(f) kids=\(kids.count)\n"
            if depth < 14 && !["AXRow", "AXCell"].contains(role) { kids.forEach { walk($0, depth + 1) } }
        }
        (axAttr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).forEach { walk($0, 0) }
    } else {
        out += "KakaoTalk not running\n"
    }
    writePrivate(Data(out.utf8), to: path)
}
#endif

// MARK: - 광고 찾기

struct AdTarget {
    let window: AXUIElement
    let ad: AXUIElement
    /// 왼쪽 탭 막대 너비. 판을 탭 막대 색과 목록 색 두 칸으로 칠할 때 쓴다.
    let sidebarWidth: CGFloat
}

/// 메인 창의 직속 자식 중 창 아래쪽에 창 너비로 붙은 AXGroup 이 광고 자리다. 광고가 로드되기 전에는 비어 있다.
func findAd(pid: pid_t) -> AdTarget? {
    let app = AXUIElementCreateApplication(pid)
    for w in axAttr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        guard axAttr(w, kAXIdentifierAttribute) as? String == "Main Window",
              let wf = axFrame(w) else { continue }
        let kids = axChildren(w)
        let listX = kids.compactMap { e -> CGFloat? in
            axAttr(e, kAXRoleAttribute) as? String == kAXScrollAreaRole ? axFrame(e)?.minX : nil
        }.min()
        for c in kids where axAttr(c, kAXRoleAttribute) as? String == kAXGroupRole {
            guard let f = axFrame(c) else { continue }
            if abs(f.maxY - wf.maxY) < 2, abs(f.width - wf.width) < 2, (40...200).contains(f.height) {
                return AdTarget(window: w, ad: c, sidebarWidth: (listX ?? wf.minX) - wf.minX)
            }
        }
    }
    return nil
}

/// AX 창과 같은 프레임의 화면 위 CGWindowID 와, 카카오톡의 다른 창(대화창 등)이 그 위에서 광고 자리를 덮고 있는지.
/// 다른 Space 에 있거나 최소화돼 있으면 nil. knownID 가 화면에 있으면 프레임 대신 그것으로 찾는다.
/// 리사이즈 중에는 AX 프레임과 CG 프레임이 잠깐 어긋나서, 프레임으로만 찾으면 판이 꺼졌다 켜진다.
func windowState(pid: pid_t, frame: CGRect, adRect: CGRect, knownID: CGWindowID? = nil) -> (id: CGWindowID, overlapped: Bool)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var overlapped = false
    // 목록은 앞쪽 창부터 온다
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { continue }
        let id = w[kCGWindowNumber as String] as? CGWindowID
        if let id, knownID.map({ $0 == id }) ?? (r.integral == frame.integral) { return (id, overlapped) }
        if r.intersects(adRect) { overlapped = true }
    }
    return nil
}

// MARK: - 창 서버 알림

/// 비공개 SkyLight API. 창 서버가 카카오톡 창을 옮기는 그 순간 알림을 받아, 접근성 알림보다 빨리 판을 옮긴다.
/// 다른 앱 창에 테두리를 그리는 JankyBorders 가 같은 방식으로 창을 따라간다. macOS 업데이트로 없어지면 nil 이 되고
/// 그때는 접근성 알림만으로 따라간다.
enum SkyLight {
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
    static let mainConnectionID = sym("SLSMainConnectionID", (@convention(c) () -> Int32).self)
    static let registerNotifyProc = sym("SLSRegisterNotifyProc",
        (@convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
    static let requestNotifications = sym("SLSRequestNotificationsForWindows",
        (@convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32).self)
    static let getWindowBounds = sym("SLSGetWindowBounds",
        (@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32).self)
    static let moveWindow = sym("SLSMoveWindow",
        (@convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32).self)
    static let windowMove: UInt32 = 806
    static let windowResize: UInt32 = 807
}

let windowServerHandler: SkyLight.NotifyProc = { _, data, _, _ in
    guard let wid = data?.load(as: UInt32.self) else { return }
    if Thread.isMainThread { delegate.windowServerMoved(wid) }
    else { DispatchQueue.main.async { delegate.windowServerMoved(wid) } }
}

// MARK: - 덮개 판

final class CoverView: NSView {
    var sidebarWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var sidebarColor = NSColor.black { didSet { needsDisplay = true } }
    var listColor = NSColor.black { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        listColor.setFill()
        bounds.fill()
        sidebarColor.setFill()
        NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
    }
}

final class Cover {
    let panel: NSPanel
    let view = CoverView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false  // 광고가 눌리지 않게 클릭을 판이 받는다
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = view
        // 창 모서리가 둥글어서 아래 두 모서리를 맞춰 깎는다
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.backgroundColor = .clear
        panel.isOpaque = false
    }

    /// floating 은 카카오톡이 앞에 있을 때만 켠다. 그래야 카카오톡 창을 클릭해도 판이 밑으로 깔리지 않고,
    /// 다른 앱으로 넘어가면 그 앱 창을 가리지 않는다.
    func show(axRect: CGRect, above windowID: CGWindowID, floating: Bool) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        panel.level = floating ? .floating : .normal
        panel.order(.above, relativeTo: Int(windowID))
    }

    /// 창 서버 알림에서 부른다. 순서와 층은 그대로 두고 자리만 옮긴다.
    func move(axRect: CGRect) {
        // 크기가 같으면 AppKit 을 거치지 않고 창 서버에 바로 옮기게 한다. AppKit 은 다음 화면 갱신 때 반영한다
        if axRect.size == panel.frame.size, let cid = SkyLight.mainConnectionID?(), let moveWindow = SkyLight.moveWindow {
            var origin = axRect.origin
            if moveWindow(cid, UInt32(panel.windowNumber), &origin) == 0 { return }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height),
                       display: true)
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }
}

// MARK: - 색 맞추기

/// 메인 창(과 덮개 판)만 골라 화면의 rect(AX 좌표) 자리를 찍는다. 대화창이 위에 있어도 메인 창이 찍힌다.
/// 화면 기록 권한이 없으면 nil.
func captureKakao(rect: CGRect, scale: CGFloat, windowID: CGWindowID, withCover: Bool) async -> CGImage? {
    guard let content = try? await SCShareableContent.current,
          let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
    let config = SCStreamConfiguration()
    config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    config.width = Int(rect.width * scale)
    config.height = Int(rect.height * scale)
    config.showsCursor = false
    let windows = content.windows.filter {
        $0.windowID == windowID || (withCover && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier)
    }
    return try? await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: display, including: windows), configuration: config)
}

/// 화면 기록 권한이 있으면 광고 바로 위 한 줄에서 탭 막대 색과 목록 색을 뽑는다.
func sampleColors(adRect: CGRect, sidebarWidth: CGFloat, windowID: CGWindowID) async -> (NSColor, NSColor)? {
    // 1pt 높이로 찍으면 값이 뭉개져서 몇 pt 띠를 레티나 배율로 찍고 가운데를 읽는다
    let strip = CGRect(x: adRect.minX, y: adRect.minY - 6, width: adRect.width, height: 4)
    guard CGPreflightScreenCaptureAccess(), let img = await captureKakao(rect: strip, scale: 2, windowID: windowID, withCover: false) else { return nil }
    // 캡처 이미지의 픽셀 순서와 색 공간을 그대로 믿지 않고, 같은 색 공간의 RGBA 버퍼에 다시 그려 읽는다.
    // 알파는 1 로 둔다. 반투명이면 판 뒤의 다른 창이 비쳐 보인다.
    guard let cgSpace = img.colorSpace, let cs = NSColorSpace(cgColorSpace: cgSpace) else { return nil }
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    guard let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                              bytesPerRow: img.width * 4, space: cgSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    func color(_ x: Int) -> NSColor {
        let i = (4 * img.width + x) * 4
        let c = [CGFloat(buf[i]) / 255, CGFloat(buf[i + 1]) / 255, CGFloat(buf[i + 2]) / 255, 1]
        return NSColor(colorSpace: cs, components: c, count: 4)
    }
    return (color(8), color(Int(sidebarWidth * 2) + 8))
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let cover = Cover()
    var target: AdTarget?
    var enabled = true
    var lastScan = Date.distantPast
    var sampledFor: String?  // 이 조합(화면 모드)에 대해 색을 뽑았으면 다시 뽑지 않는다
    var timer: Timer?
    var observer: AXObserver?
    var observedPID: pid_t = 0
    var windowID: CGWindowID?
    var subscribedID: CGWindowID?
    var adHeight: CGFloat = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        // 확인용 명령은 개발용 빌드에만 있다. 배포용 빌드에 두면 다른 프로그램이 이 앱을 그 인자로 띄워
        // 이 앱이 받은 접근성, 화면 기록 권한으로 카카오톡 화면과 창 내용을 가져갈 수 있다.
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
            dumpTree(to: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--followtest") {
            followTest(delayMs: i + 1 < args.count ? Int(args[i + 1]) ?? 16 : 16)
            NSApp.terminate(nil)
            return
        }
        if args.contains("--login-on") {
            try? SMAppService.mainApp.register()
            FileHandle.standardError.write(Data("login item: \(SMAppService.mainApp.status.rawValue)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
            Task { @MainActor in
                await saveShot(to: args[i + 1])
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        applyFallbackColors()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "K"
        rebuildMenu()

        // 창 이동, 크기 변경, 앱 전환은 알림으로 바로 맞추고, 광고가 새로 뜨는 것 같은 나머지는 0.5초마다 본다
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        if let register = SkyLight.registerNotifyProc {
            _ = register(windowServerHandler, SkyLight.windowMove, nil)
            _ = register(windowServerHandler, SkyLight.windowResize, nil)
        }
        // 크기 변경은 창 서버 알림이 오지 않고 접근성 알림은 띄엄띄엄 와서, 끄는 동안 마우스 이벤트마다
        // 창 서버에서 창 크기를 바로 읽어 판을 맞춘다. 놓으면 접근성으로 한 번 더 맞춘다.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == kakaoBundleID else { return }
            if e.type == .leftMouseDragged, let id = self.windowID { self.windowServerMoved(id) } else { self.tick() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged), name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "광고 가리기", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        let login = menu.addItem(withTitle: "로그인 시 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "색 다시 맞추기", action: #selector(resample), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    @objc func toggleEnabled() { enabled.toggle(); rebuildMenu(); tick() }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        try? (s.status == .enabled ? s.unregister() : s.register())
        rebuildMenu()
    }

    @objc func resample() { sampledFor = nil }

    @objc func appearanceChanged() { applyFallbackColors(); sampledFor = nil }

    /// 화면 기록 권한이 없을 때 쓰는 카카오톡 기본 테마 색
    func applyFallbackColors() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cover.view.sidebarColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        cover.view.listColor = dark ? NSColor(white: 0.17, alpha: 1) : .white
    }

    func tick() {
        guard enabled, AXIsProcessTrusted(),
              let kakao = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundleID).first,
              !kakao.isHidden else { cover.hide(); target = nil; return }
        let pid = kakao.processIdentifier
        observe(pid: pid)

        if target == nil || Date().timeIntervalSince(lastScan) > 1 {
            // 리사이즈 도중에는 창과 광고 프레임이 잠깐 어긋나 못 찾을 수 있어서, 그때는 찾아 둔 것을 계속 쓴다
            target = findAd(pid: pid) ?? target
            lastScan = Date()
        }
        guard let t = target, let adRect = axFrame(t.ad), let winRect = axFrame(t.window),
              let state = windowState(pid: pid, frame: winRect, adRect: adRect, knownID: windowID)
                ?? windowState(pid: pid, frame: winRect, adRect: adRect) else { cover.hide(); windowID = nil; return }
        windowID = state.id
        adHeight = adRect.height
        if subscribedID != state.id, let cid = SkyLight.mainConnectionID?(), let request = SkyLight.requestNotifications {
            var wid = state.id
            _ = request(cid, &wid, 1)
            subscribedID = state.id
        }

        cover.view.sidebarWidth = t.sidebarWidth
        cover.show(axRect: adRect, above: state.id, floating: kakao.isActive && !state.overlapped)

        let key = NSApp.effectiveAppearance.name.rawValue
        if sampledFor != key {
            sampledFor = key
            Task { @MainActor in
                if let (side, list) = await sampleColors(adRect: adRect, sidebarWidth: t.sidebarWidth, windowID: state.id) {
                    cover.view.sidebarColor = side
                    cover.view.listColor = list
                }
            }
        }
    }
}

extension AppDelegate {
    /// 광고는 메인 창 아래쪽에 창 너비로 붙어 있으니, 창 서버가 알려 준 창 프레임만으로 광고 자리를 계산한다
    func windowServerMoved(_ wid: UInt32) {
        guard wid == windowID, enabled, adHeight > 0, cover.panel.isVisible,
              let cid = SkyLight.mainConnectionID?(), let getBounds = SkyLight.getWindowBounds else { return }
        var r = CGRect.zero
        guard getBounds(cid, wid, &r) == 0 else { return }
        cover.move(axRect: CGRect(x: r.minX, y: r.maxY - adHeight, width: r.width, height: adHeight))
    }

    /// 카카오톡 창이 움직이거나 크기가 바뀌면 바로 판을 옮긴다
    func observe(pid: pid_t) {
        guard pid != observedPID else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        observedPID = pid
        target = nil
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue().tick()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, appElement, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }
}

#if DEBUG
/// 확인용: 카카오톡 창과 덮개 판만 골라 메인 창 자리를 PNG 로 남긴다. 화면 기록 권한이 필요하다.
func saveShot(to path: String) async {
    guard let kakao = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundleID).first,
          let t = findAd(pid: kakao.processIdentifier), let win = axFrame(t.window), let ad = axFrame(t.ad),
          let state = windowState(pid: kakao.processIdentifier, frame: win, adRect: ad),
          let img = await captureKakao(rect: win, scale: 2, windowID: state.id, withCover: true),
          let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("shot failed (screen recording permission?)\n".utf8))
        return
    }
    writePrivate(png, to: path)
}

/// 확인용: 카카오톡 메인 창을 접근성 API 로 조금씩 옮기고 키우면서, 매 단계 16ms 뒤에 실행 중인 가림막이
/// 광고 자리에 와 있는지 센다. 끝나면 창을 원래 위치와 크기로 돌려놓는다.
func followTest(delayMs: Int) {
    guard let kakao = NSRunningApplication.runningApplications(withBundleIdentifier: kakaoBundleID).first,
          let t = findAd(pid: kakao.processIdentifier), let start = axFrame(t.window), let ad = axFrame(t.ad) else {
        print("no target"); return
    }
    let adHeight = ad.height
    func bounds() -> (kakao: CGRect?, cover: CGRect?) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var k: CGRect?, c: CGRect?
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            let pid = w[kCGWindowOwnerPID as String] as? pid_t
            if pid == kakao.processIdentifier, r.height > 300 { k = k ?? r }
            if w[kCGWindowOwnerName as String] as? String == "KakaoAdCover", pid != getpid() { c = r }
        }
        return (k, c)
    }
    func set(_ e: AXUIElement, _ attr: String, _ v: CGPoint) {
        var x = v
        AXUIElementSetAttributeValue(e, attr as CFString, AXValueCreate(.cgPoint, &x)!)
    }
    func set(_ e: AXUIElement, _ attr: String, _ v: CGSize) {
        var x = v
        AXUIElementSetAttributeValue(e, attr as CFString, AXValueCreate(.cgSize, &x)!)
    }
    var misses = [String: Int]()
    for (name, steps) in [("move", 40), ("resize", 40)] {
        var miss = 0
        for i in 1...steps {
            let d = CGFloat(i * 3)
            if name == "move" { set(t.window, kAXPositionAttribute, CGPoint(x: start.minX + d, y: start.minY)) }
            else { set(t.window, kAXSizeAttribute, CGSize(width: start.width, height: start.height - d)) }
            usleep(useconds_t(delayMs * 1000))
            let (k, c) = bounds()
            if let k, let c, abs(c.minX - k.minX) < 1, abs(c.maxY - k.maxY) < 1, abs(c.height - adHeight) < 1 { continue }
            miss += 1
        }
        misses[name] = miss
        set(t.window, kAXSizeAttribute, start.size)
        set(t.window, kAXPositionAttribute, start.origin)
        usleep(300_000)
    }
    print("steps 40 each, cover off-position after \(delayMs)ms: move=\(misses["move"]!) resize=\(misses["resize"]!)")
}

#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
