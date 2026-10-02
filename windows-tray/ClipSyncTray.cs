// ClipSync 通知區小圖示(Windows 原生,對應 macOS 的選單列 App)。
//
// 分工和 macos-menubar/main.swift 一模一樣:Dart 背景服務負責所有同步邏輯,
// 這支只是一層薄薄的原生外皮,透過 http://127.0.0.1:53320 的本機 API
// 讀狀態、按暫停。核心仍然是純 Dart。
//
// 為什麼能不裝任何東西就編譯:每一台 Windows 都內建 .NET Framework 的
// C# 編譯器(csc.exe),win-設定開機自動啟動.bat 安裝時會自動把這個檔案
// 編成 ClipSyncTray.exe。語法刻意停在 C# 5 —— 內建的 csc 只認得到這一版。
//
// 存檔格式:UTF-8 with BOM(沒有 BOM 的話 csc 會用系統編碼讀,中文全毀)。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ── 只挑我們要的欄位;JSON 裡多出來的(events 等)會被自動忽略 ──
[DataContract]
class PeerDto {
    [DataMember(Name = "name")] public string Name;
    [DataMember(Name = "platform")] public string Platform;
    [DataMember(Name = "ip")] public string Ip;
    [DataMember(Name = "failures")] public int Failures;
    [DataMember(Name = "compatible")] public bool Compatible;
}

[DataContract]
class StatusDto {
    [DataMember(Name = "paused")] public bool Paused;
    [DataMember(Name = "sent")] public int Sent;
    [DataMember(Name = "recv")] public int Recv;
    [DataMember(Name = "inbox")] public string Inbox;
    [DataMember(Name = "peers")] public PeerDto[] Peers;
}

[DataContract]
class SendDto {
    [DataMember(Name = "text")] public string Text;
}

// ── 「送一段文字」的小視窗 ──
class SendForm : Form {
    public TextBox Box;
    public SendForm() {
        Text = "送一段文字到另一台電腦";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(370, 106);

        Label tip = new Label();
        tip.Text = "對方會直接收進剪貼簿,貼上就有。";
        tip.SetBounds(12, 10, 346, 20);

        Box = new TextBox();
        Box.SetBounds(12, 34, 346, 24);

        Button ok = new Button();
        ok.Text = "送出";
        ok.DialogResult = DialogResult.OK;
        ok.SetBounds(202, 68, 75, 28);

        Button cancel = new Button();
        cancel.Text = "取消";
        cancel.DialogResult = DialogResult.Cancel;
        cancel.SetBounds(283, 68, 75, 28);

        AcceptButton = ok;
        CancelButton = cancel;
        Controls.Add(tip);
        Controls.Add(Box);
        Controls.Add(ok);
        Controls.Add(cancel);
    }
}

class TrayContext : ApplicationContext {
    const string Base = "http://127.0.0.1:53320";

    NotifyIcon tray;
    ContextMenuStrip menu;
    System.Windows.Forms.Timer timer;
    StatusDto status; // null = 背景服務沒在跑
    Icon icoOnline, icoPaused, icoOffline;

    public TrayContext() {
        Icon baseIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        icoOnline = baseIcon;
        icoPaused = WithDot(baseIcon, Color.FromArgb(217, 119, 6));  // 橘:暫停
        icoOffline = WithDot(baseIcon, Color.FromArgb(220, 38, 38)); // 紅:沒在跑

        menu = new ContextMenuStrip();
        menu.Opening += delegate { RefreshStatus(); Rebuild(); };

        tray = new NotifyIcon();
        tray.Icon = icoOffline;
        tray.Text = "ClipSync";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.DoubleClick += delegate { OpenPanel(); };

        RefreshStatus();
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 3000;
        timer.Tick += delegate { RefreshStatus(); };
        timer.Start();
    }

    // 圖示右下角疊一顆狀態點(和網頁控制台的顏色一致)。
    static Icon WithDot(Icon baseIcon, Color color) {
        Bitmap bmp = new Bitmap(32, 32);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.DrawIcon(baseIcon, new Rectangle(0, 0, 32, 32));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Brush ring = new SolidBrush(Color.White))
                g.FillEllipse(ring, 15, 15, 17, 17);
            using (Brush dot = new SolidBrush(color))
                g.FillEllipse(dot, 18, 18, 11, 11);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ── 跟背景服務講話(都打 127.0.0.1,毫秒級,直接同步呼叫即可)──
    void RefreshStatus() {
        try {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Base + "/api/status");
            req.Timeout = 1500;
            req.ReadWriteTimeout = 1500;
            using (WebResponse resp = req.GetResponse())
            using (Stream s = resp.GetResponseStream()) {
                DataContractJsonSerializer ser =
                    new DataContractJsonSerializer(typeof(StatusDto));
                status = (StatusDto)ser.ReadObject(s);
            }
        } catch (Exception) {
            status = null;
        }
        tray.Icon = status == null ? icoOffline : (status.Paused ? icoPaused : icoOnline);
        tray.Text = status == null ? "ClipSync — 沒有在執行"
                  : (status.Paused ? "ClipSync — 已暫停" : "ClipSync — 同步中");
    }

    void Post(string path, string jsonBody) {
        try {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Base + path);
            req.Method = "POST";
            req.Timeout = 3000;
            // 控制台 API 的 CSRF 防護標頭(見 src/webui.dart)
            req.Headers["x-clipsync-ui"] = "1";
            req.ContentType = "application/json";
            byte[] body = Encoding.UTF8.GetBytes(jsonBody == null ? "{}" : jsonBody);
            req.ContentLength = body.Length;
            using (Stream s = req.GetRequestStream())
                s.Write(body, 0, body.Length);
            req.GetResponse().Close();
        } catch (Exception) { }
        RefreshStatus();
    }

    // ── 選單:每次打開都重建,內容永遠是現況 ──
    ToolStripMenuItem Info(string text) {
        ToolStripMenuItem it = new ToolStripMenuItem(text);
        it.Enabled = false;
        return it;
    }

    void Rebuild() {
        menu.Items.Clear();

        if (status == null) {
            menu.Items.Add(Info("✗ ClipSync 沒有在執行"));
            menu.Items.Add("▶ 啟動 ClipSync", null, delegate { StartAgent(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("結束通知區圖示", null, delegate { QuitApp(); });
            return;
        }

        menu.Items.Add(Info(status.Paused ? "ClipSync — ⏸ 已暫停" : "ClipSync — ✓ 同步中"));
        menu.Items.Add(Info(string.Format("送出 {0} 次 · 收到 {1} 次", status.Sent, status.Recv)));
        menu.Items.Add(new ToolStripSeparator());

        if (status.Peers == null || status.Peers.Length == 0) {
            menu.Items.Add(Info("還沒發現其他電腦"));
        } else {
            foreach (PeerDto p in status.Peers) {
                string icon = p.Platform == "windows" ? "🪟"
                            : p.Platform == "macos" ? "🍎" : "💻";
                string line = string.Format("{0} {1} — {2}", icon, p.Name, p.Ip);
                if (!p.Compatible) line += "  ⚠ 版本不合";
                else if (p.Failures > 0) line += "  ⚠ 送不進去";
                menu.Items.Add(Info(line));
            }
        }
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(status.Paused ? "▶ 恢復同步" : "⏸ 暫停同步", null,
            delegate { Post(status != null && status.Paused ? "/api/resume" : "/api/pause", null); });
        menu.Items.Add("📨 送一段文字到另一台…", null, delegate { SendText(); });
        menu.Items.Add("🔁 把目前剪貼簿再推一次", null, delegate { Post("/api/push", null); });
        menu.Items.Add("📂 打開收到的檔案", null, delegate { OpenInbox(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("完整控制台(網頁)…", null, delegate { OpenPanel(); });
        menu.Items.Add("結束通知區圖示", null, delegate { QuitApp(); });
    }

    // ── 動作 ──
    void SendText() {
        using (SendForm f = new SendForm()) {
            if (f.ShowDialog() != DialogResult.OK) return;
            string t = f.Box.Text;
            if (t == null || t.Trim().Length == 0) return;
            SendDto dto = new SendDto();
            dto.Text = t;
            using (MemoryStream ms = new MemoryStream()) {
                new DataContractJsonSerializer(typeof(SendDto)).WriteObject(ms, dto);
                Post("/api/send", Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
    }

    void OpenInbox() {
        string path = status == null ? null : status.Inbox;
        if (path != null && Directory.Exists(path)) {
            Process.Start("explorer.exe", "\"" + path + "\"");
        } else {
            MessageBox.Show(
                "還沒收過檔案。收到第一個檔案時,資料夾會自動出現在:\n" +
                (path == null ? "(未知)" : path),
                "ClipSync", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    void OpenPanel() {
        try { Process.Start(Base); } catch (Exception) { }
    }

    void StartAgent() {
        // 「啟動」資料夾裡的 ClipSync.vbs 會把背景服務(和本圖示)一起帶起來。
        string vbs = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ClipSync.vbs");
        if (File.Exists(vbs)) {
            Process.Start("wscript.exe", "\"" + vbs + "\"");
        } else {
            MessageBox.Show("還沒設定自動啟動。請到 ClipSync 資料夾點兩下 win-設定開機自動啟動.bat。",
                "ClipSync", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    void QuitApp() {
        tray.Visible = false;
        Application.Exit();
    }
}

static class Program {
    [STAThread]
    static void Main() {
        // 同一時間只能有一個圖示(重複執行時安靜退出)。
        bool createdNew;
        using (Mutex m = new Mutex(true, "ClipSyncTrayMutex", out createdNew)) {
            if (!createdNew) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
    }
}
