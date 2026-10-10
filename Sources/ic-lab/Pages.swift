import Foundation
import ICSystem

/// Local pages for the side-effect lab. Each page reports its state to the lab server
/// every second (`POST /report`) and follows `/control.json`, which the lab writes.
extension Lab {
    static let labJS = """
        const PAGE = document.currentScript.dataset.page;
        let control = {};
        function report(state, extra) {
          fetch('/report', {method: 'POST', body: JSON.stringify(Object.assign({page: PAGE, state: state, wall: Date.now(), mono: performance.now()}, extra || {}))}).catch(() => {});
        }
        async function poll() {
          try { control = await (await fetch('/control.json?' + Date.now())).json(); } catch (e) {}
        }
        setInterval(poll, 1000);
        """

    static func page(_ name: String, _ body: String, _ script: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>iClear lab: \(name)</title>
        <body><h3>iClear lab page: \(name)</h3>\(body)
        <script src="lab.js" data-page="\(name)"></script>
        <script>\(script)</script></body>
        """
    }

    static func writePages(_ www: URL) {
        var files: [String: String] = ["lab.js": labJS]
        files["form.html"] = page(
            "form", "<input id=f size=40><textarea id=a></textarea>",
            """
            const v = 'lab-' + Math.random().toString(36).slice(2);
            f.value = v; a.value = v + '-long';
            setInterval(() => report('value=' + f.value + '/' + a.value), 1000);
            """)
        files["timers.html"] = page(
            "timers", "",
            """
            let ticks = 0, last = Date.now(), lastGap = 0, burst = 0, prev = 0;
            setInterval(() => {
              const n = Date.now(); const gap = n - last; last = n; ticks++;
              if (gap > 1500) { lastGap = gap; burst = 0; prev = n; } else if (n - prev < 200) { burst++; }
              report('ticks=' + ticks + ' lastGapMs=' + lastGap + ' burstAfterGap=' + burst);
            }, 1000);
            """)
        files["ws.html"] = page(
            "ws", "",
            """
            let ws, state = 'connecting', connects = 0, backoff = 1000;
            function open() {
              ws = new WebSocket('ws://127.0.0.1:\(wsPort)');
              ws.onopen = () => { state = 'open'; connects++; backoff = 1000; ws.send(JSON.stringify({type: 'hello', name: 'chrome'})); };
              ws.onmessage = (e) => { const m = JSON.parse(e.data);
                if (m.type === 'ping') ws.send(JSON.stringify({type: 'pong'}));
                if (m.type === 'msg') ws.send(JSON.stringify({type: 'ack', seq: m.seq})); };
              ws.onclose = () => { state = 'closed'; setTimeout(open, backoff); backoff = Math.min(backoff * 2, 30000); };
            }
            open();
            setInterval(() => report(state + ' connects=' + connects), 1000);
            """)
        // Wake-on-Data: only the WebSocket, no polling, so the tab is quiet between messages.
        files["chat.html"] =
            """
            <!doctype html><meta charset="utf-8"><title>iClear lab: chat</title><body><h3>iClear lab page: chat</h3>
            <script>
            let backoff = 1000;
            function open() {
              const ws = new WebSocket('ws://127.0.0.1:\(wsPort)');
              ws.onopen = () => { backoff = 1000; ws.send(JSON.stringify({type: 'hello', name: location.hash.slice(1) || 'chrome'})); };
              ws.onmessage = (e) => { const m = JSON.parse(e.data);
                if (m.type === 'ping') ws.send(JSON.stringify({type: 'pong'}));
                if (m.type === 'msg') ws.send(JSON.stringify({type: 'ack', seq: m.seq})); };
              ws.onclose = () => { setTimeout(open, backoff); backoff = Math.min(backoff * 2, 30000); };
            }
            open();
            </script></body>
            """
        files["webrtc.html"] = page(
            "webrtc", "",
            """
            const pc1 = new RTCPeerConnection(), pc2 = new RTCPeerConnection();
            pc1.onicecandidate = (e) => e.candidate && pc2.addIceCandidate(e.candidate);
            pc2.onicecandidate = (e) => e.candidate && pc1.addIceCandidate(e.candidate);
            const dc = pc1.createDataChannel('lab'); let recv = 0, lastRecv = Date.now();
            pc2.ondatachannel = (e) => { e.channel.onmessage = () => { recv++; lastRecv = Date.now(); }; };
            (async () => {
              const o = await pc1.createOffer(); await pc1.setLocalDescription(o); await pc2.setRemoteDescription(o);
              const a = await pc2.createAnswer(); await pc2.setLocalDescription(a); await pc1.setRemoteDescription(a);
            })();
            setInterval(() => { if (dc.readyState === 'open') dc.send('x'); }, 1000);
            setInterval(() => report(dc.readyState + ' ice=' + pc1.iceConnectionState + ' received=' + recv + ' lastMsgAgoMs=' + (Date.now() - lastRecv)), 1000);
            """)
        files["sw.js"] = """
            self.addEventListener('install', (e) => self.skipWaiting());
            self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
            self.addEventListener('message', (e) => {
              const m = e.data || {};
              if (m.notifyInMs) {
                const due = Date.now() + m.notifyInMs;
                setTimeout(() => {
                  const late = Date.now() - due;
                  self.registration.showNotification('iClear lab test notification', {body: 'late by ' + late + ' ms'})
                    .then(() => fetch('/report', {method: 'POST', body: JSON.stringify({page: 'sw-notify', state: 'shown late ' + late})}))
                    .catch((err) => fetch('/report', {method: 'POST', body: JSON.stringify({page: 'sw-notify', state: 'not shown: ' + err})}));
                }, m.notifyInMs);
              }
              e.source && e.source.postMessage({pong: Date.now()});
            });
            """
        files["sw.html"] = page(
            "sw", "",
            """
            let lastPong = 0, notified = false;
            navigator.serviceWorker.register('sw.js').then(() => navigator.serviceWorker.ready).then((reg) => {
              navigator.serviceWorker.onmessage = (e) => { lastPong = Date.now(); };
              setInterval(() => {
                const msg = {};
                if (control.notify && !notified) { msg.notifyInMs = control.notify; notified = true; }
                if (!control.notify) notified = false;
                reg.active && reg.active.postMessage(msg);
              }, 1000);
            });
            setInterval(() => report((Date.now() - lastPong < 3000 ? 'alive' : 'silent') + ' permission=' + Notification.permission), 1000);
            """)
        files["media.html"] = page(
            "media", "<audio id=m src=tone.wav loop></audio>",
            "setInterval(() => report((m.paused ? 'paused' : 'playing') + ' t=' + m.currentTime.toFixed(1)), 1000);")
        files["audio.html"] = page(
            "audio", "",
            """
            let ctx = null;
            setInterval(() => {
              if (control.audio && !ctx) { ctx = new AudioContext(); const o = ctx.createOscillator(), g = ctx.createGain();
                g.gain.value = 0.003; o.connect(g).connect(ctx.destination); o.start(); }
              if (!control.audio && ctx) { ctx.close(); ctx = null; }
              report(ctx ? 'playing ' + ctx.state : 'silent');
            }, 1000);
            """)
        files["call.html"] = page(
            "call", "",
            """
            let stream = null, mic = 'none';
            setInterval(async () => {
              if (control.call && !stream && mic !== 'asking') {
                mic = 'asking';
                try { stream = await navigator.mediaDevices.getUserMedia({audio: true}); mic = 'live'; } catch (e) { mic = 'error ' + e.name; }
              }
              if (!control.call && stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; mic = 'none'; }
              report('mic=' + mic, {mic: mic});
            }, 1000);
            """)
        files["download.html"] = page(
            "download", "",
            """
            let started = null;
            setInterval(() => {
              if (control.download && control.download !== started) {
                started = control.download; const a = document.createElement('a'); a.href = control.download; a.download = 'lab-download.bin';
                document.body.appendChild(a); a.click();
              }
              if (!control.download) started = null;
              report(started ? 'started' : 'idle');
            }, 1000);
            """)
        for (name, text) in files { try? Data(text.utf8).write(to: www.appendingPathComponent(name)) }
        try? toneWAV().write(to: www.appendingPathComponent("tone.wav"))
        try? Data("{}".utf8).write(to: www.appendingPathComponent("index.html"))
    }

    /// One second of a quiet 440 Hz tone, 16-bit mono WAV.
    static func toneWAV() -> Data {
        let rate = 22_050
        var pcm = Data()
        for i in 0..<rate {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 100)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8) + u32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        d += u32(16) + u16(1) + u16(1) + u32(UInt32(rate)) + u32(UInt32(rate * 2)) + u16(2) + u16(16)
        d += Data("data".utf8) + u32(UInt32(pcm.count)) + pcm
        return d
    }

    /// A throwaway profile that saves downloads to `downloads` without asking and allows
    /// notifications and the microphone for the lab's local origin only.
    static func writeChromePrefs(_ dataDir: URL, downloads: URL) {
        let origin = "http://127.0.0.1:\(httpPort),*"
        let prefs: [String: Any] = [
            "download": ["default_directory": downloads.path, "prompt_for_download": false, "directory_upgrade": true],
            "savefile": ["default_directory": downloads.path],
            "profile": [
                "content_settings": [
                    "exceptions": [
                        "notifications": [origin: ["setting": 1]], "media_stream_mic": [origin: ["setting": 1]],
                        "automatic_downloads": [origin: ["setting": 1]],
                    ]
                ]
            ],
        ]
        let dir = dataDir.appendingPathComponent("Default")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: prefs) { try? d.write(to: dir.appendingPathComponent("Preferences")) }
    }
}
