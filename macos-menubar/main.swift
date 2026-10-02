// ClipSync 選單列 App(macOS 原生,像 Mos 那種:右上角一個圖示,點開是選單)。
//
// 分工:Dart 主程式(背景服務)負責所有同步邏輯,本檔只是一層很薄的
// 原生外皮 —— 透過 http://127.0.0.1:53320 的本機 API 讀狀態、按暫停。
// 這樣專題的核心仍然是純 Dart;原生 UI 是各平台自己的一小片皮
// (macOS 用這個,Windows 用網頁控制台)。
//
// 編譯(mac-設定開機自動啟動.command 只負責複製,編譯在開發機做一次):
//   swiftc -O -swift-version 5 main.swift -o ClipSyncMenuBar

import AppKit
import Foundation

let kBase = "http://127.0.0.1:53320"

func apiURL(_ path: String) -> URL { URL(string: kBase + path)! }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?

    /// 最近一次 /api/status 的內容;nil = 背景服務沒在跑。
    var status: [String: Any]?

    var paused: Bool { (status?["paused"] as? Bool) ?? false }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "ClipSync"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        refresh()
        // 3 秒更新一次圖示狀態(選單打開瞬間另外再抓一次)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // ── 圖示:一眼看出狀態 ──────────────────────────────────────
    func updateIcon() {
        let name: String
        if status == nil { name = "exclamationmark.arrow.circlepath" } // 服務沒跑
        else if paused { name = "pause.circle" }                       // 已暫停
        else { name = "doc.on.clipboard" }                             // 同步中
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "ClipSync")
        img?.isTemplate = true // 跟著選單列自動變黑/變白
        statusItem.button?.image = img
    }

    // ── 跟背景服務講話 ─────────────────────────────────────────
    func refresh() {
        var req = URLRequest(url: apiURL("/api/status"))
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var s: [String: Any]?
            if let d = data,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                s = j
            }
            DispatchQueue.main.async {
                self.status = s
                self.updateIcon()
            }
        }.resume()
    }

    func post(_ path: String, body: [String: Any]? = nil) {
        var req = URLRequest(url: apiURL(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        // 控制台 API 的 CSRF 防護標頭(見 src/webui.dart)
        req.setValue("1", forHTTPHeaderField: "x-clipsync-ui")
        if let b = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        URLSession.shared.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async { self.refresh() }
        }.resume()
    }

    // ── 選單:每次打開都重建,內容永遠是現況 ─────────────────────
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuild()
    }

    func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.isEnabled = true
        return it
    }

    func rebuild() {
        menu.removeAllItems()

        guard let s = status else {
            menu.addItem(info("✗ ClipSync 沒有在執行"))
            menu.addItem(action("▶ 啟動 ClipSync", #selector(startAgent)))
            menu.addItem(.separator())
            menu.addItem(action("結束選單列圖示", #selector(quitApp)))
            return
        }

        menu.addItem(info(paused ? "ClipSync — ⏸ 已暫停" : "ClipSync — ✓ 同步中"))
        let sent = (s["sent"] as? Int) ?? 0
        let recv = (s["recv"] as? Int) ?? 0
        menu.addItem(info("送出 \(sent) 次 · 收到 \(recv) 次"))
        menu.addItem(.separator())

        let peers = (s["peers"] as? [[String: Any]]) ?? []
        if peers.isEmpty {
            menu.addItem(info("還沒發現其他電腦"))
        } else {
            for p in peers {
                let plat = (p["platform"] as? String) ?? "?"
                let icon = plat == "windows" ? "🪟" : (plat == "macos" ? "🍎" : "💻")
                let name = (p["name"] as? String) ?? "?"
                let ip = (p["ip"] as? String) ?? "?"
                let fails = (p["failures"] as? Int) ?? 0
                let ok = (p["compatible"] as? Bool) ?? true
                var line = "\(icon) \(name) — \(ip)"
                if !ok { line += "  ⚠ 版本不合" } else if fails > 0 { line += "  ⚠ 送不進去" }
                menu.addItem(info(line))
            }
        }
        menu.addItem(.separator())

        menu.addItem(action(paused ? "▶ 恢復同步" : "⏸ 暫停同步", #selector(togglePause)))
        menu.addItem(action("📨 送一段文字到另一台…", #selector(sendText)))
        menu.addItem(action("🔁 把目前剪貼簿再推一次", #selector(pushClipboard)))
        menu.addItem(action("📂 打開收到的檔案", #selector(openInbox)))
        menu.addItem(.separator())
        menu.addItem(action("完整控制台(網頁)…", #selector(openPanel)))
        menu.addItem(action("結束選單列圖示", #selector(quitApp)))
    }

    // ── 動作 ───────────────────────────────────────────────────
    @objc func togglePause() { post(paused ? "/api/resume" : "/api/pause") }
    @objc func pushClipboard() { post("/api/push") }
    @objc func openPanel() { NSWorkspace.shared.open(URL(string: kBase)!) }

    @objc func openInbox() {
        guard let path = status?["inbox"] as? String else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "還沒收過檔案"
            a.informativeText = "收到第一個檔案時,資料夾會自動出現在:\n\(path)"
            a.runModal()
        }
    }

    @objc func sendText() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "送一段文字到另一台電腦"
        a.informativeText = "對方會直接收進剪貼簿,貼上就有。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "送出")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            let t = field.stringValue
            if !t.isEmpty { post("/api/send", body: ["text": t]) }
        }
    }

    @objc func startAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/com.clipsync.agent"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

// 進入點:純選單列 App,不出現在 Dock。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
