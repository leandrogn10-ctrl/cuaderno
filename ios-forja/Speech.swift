/*  Speech.swift — the debrief mic, done by iOS instead of by a web API the webview doesn't have.

    phone-boot-pre.js installs a Web-Speech-shaped class; its start/stop/abort land here, and every
    outcome goes back as window.__forjaSpeech(id, kind, text, isFinal). The page's own handler is
    unchanged — it thinks it is talking to the Web Speech API.

    What each rule below is guarding against (all observed or documented, none decorative):
    · iOS hands back the WHOLE transcript-so-far per callback, per TASK. A task can end (server
      recognition caps near a minute; on-device can re-segment after a pause) and the next one
      starts from empty. So a segment boundary is sent as a FINAL result, and the shim opens a new
      result slot after it — words already on screen are never replaced by a shorter partial.
    · stop() → endAudio() → the final result arrives asynchronously, and sometimes never. So a stop
      has a 1.5s deadline, after which the last partial is sent as the final and the session ends.
    · The audio session: .record would kill whatever he's listening to at the gym. playAndRecord +
      mixWithOthers/duckOthers keeps the music, and the session is released on every exit path.
    · "No speech" is not an event iOS raises; it is error 1110 at the end of a silent task. */
import Foundation
import Speech
import AVFoundation
import WebKit

final class SpeechBridge {
    weak var webView: WKWebView?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var id = 0
    private var continuous = false
    private var stopping = false
    private var ended = true
    private var tapped = false
    private var lastText = ""
    private var deadline: DispatchWorkItem?

    func handle(_ body: [String: Any]) {
        let op = body["op"] as? String ?? ""
        let reqId = body["id"] as? Int ?? 0
        switch op {
        case "start": start(id: reqId, lang: body["lang"] as? String ?? "en-US", continuous: body["continuous"] as? Bool ?? false)
        case "stop":  if reqId == id { stop() }
        case "abort": if reqId == id { finish(sendLast: false) }
        default: break
        }
    }

    // MARK: start

    private func start(id newId: Int, lang: String, continuous: Bool) {
        if !ended { finish(sendLast: false) }          // one recognizer at a time; the old one ends first
        id = newId; self.continuous = continuous; stopping = false; ended = false; lastText = ""
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard newId == self.id, !self.ended else { return }
                guard status == .authorized else { return self.fail("not-allowed", "speech recognition permission is off (Settings → La Forja)") }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard newId == self.id, !self.ended else { return }
                        guard granted else { return self.fail("not-allowed", "microphone permission is off (Settings → La Forja)") }
                        self.begin(lang: lang)
                    }
                }
            }
        }
    }

    /// 'es-PE' is what the page asks for; iOS may not carry a Peruvian model, so fall back to the
    /// nearest Spanish it does have, and say which one ran in the log.
    private func pickRecognizer(_ lang: String) -> SFSpeechRecognizer? {
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        let candidates = [lang] + (base == "es" ? ["es-US", "es-MX", "es-419", "es-ES"] : base == "en" ? ["en-US"] : [])
        for c in candidates {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: c)), r.isAvailable {
                if c != lang { Vault.shared.log("speech: \(lang) unavailable, using \(c)") }
                return r
            }
        }
        return nil
    }

    private func begin(lang: String) {
        guard let r = pickRecognizer(lang) else { return fail("language-not-supported", "no recognizer for \(lang)") }
        recognizer = r
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true, options: [])
        } catch { return fail("audio-capture", "audio session: \(error.localizedDescription)") }

        let input = engine.inputNode
        if tapped { input.removeTap(onBus: 0); tapped = false }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return fail("audio-capture", "no microphone input") }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.request?.append(buf) }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { return fail("audio-capture", "audio engine: \(error.localizedDescription)") }

        emit("start", "", false)
        beginTask()
    }

    private func beginTask() {
        guard let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        // On-device when the model is present: no network in a basement gym, and no one-minute cap.
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let myId = id
        task = r.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.onTask(myId, result, error) }
        }
    }

    private func onTask(_ taskId: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard taskId == id, !ended else { return }
        if let result {
            lastText = result.bestTranscription.formattedString
            emit("result", lastText, result.isFinal)
            if result.isFinal {
                if stopping || !continuous { return finish(sendLast: false) }
                lastText = ""; beginTask()             // a segment closed on its own: keep listening, new slot
                return
            }
        }
        guard let error else { return }
        let ns = error as NSError
        if stopping { return finish(sendLast: true) }  // the stop path: whatever we have is the final
        switch ns.code {
        case 1110:                                     // "no speech detected"
            if lastText.isEmpty { fail("no-speech", "") } else { finish(sendLast: true) }
        case 203, 1700, 216, 209:                      // the task ran out (time cap / retry): close the segment, carry on
            if continuous {
                if !lastText.isEmpty { emit("result", lastText, true) }
                lastText = ""; beginTask()
            } else { finish(sendLast: true) }
        case 301:                                      // cancelled
            finish(sendLast: false)
        default:
            Vault.shared.log("speech error \(ns.domain) \(ns.code): \(ns.localizedDescription)")
            if !lastText.isEmpty { emit("result", lastText, true) }
            fail(ns.domain.contains("Network") || ns.code == 1101 ? "network" : "service-not-allowed", ns.localizedDescription)
        }
    }

    // MARK: stop / end

    private func stop() {
        guard !ended, !stopping else { return }
        stopping = true
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        request?.endAudio()
        let myId = id
        let w = DispatchWorkItem { [weak self] in
            guard let self, myId == self.id, !self.ended else { return }
            self.finish(sendLast: true)                // the final never came: the last partial IS the final
        }
        deadline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func fail(_ code: String, _ why: String) {
        guard !ended else { return }
        Vault.shared.log("speech fail \(code): \(why)")
        emit("error", code, false, message: why)
        finish(sendLast: false)
    }

    private func finish(sendLast: Bool) {
        guard !ended else { return }
        if sendLast && !lastText.isEmpty { emit("result", lastText, true) }
        ended = true
        deadline?.cancel(); deadline = nil
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if engine.isRunning { engine.stop() }
        task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        emit("end", "", false)
    }

    // MARK: to the page

    private func emit(_ kind: String, _ text: String, _ isFinal: Bool, message: String = "") {
        let args: [Any] = [id, kind, text, kind == "error" ? message : isFinal]
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__forjaSpeech && window.__forjaSpeech.apply(null, \(json))")
    }
}
