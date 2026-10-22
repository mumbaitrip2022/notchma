import AVFoundation
import Speech

/// Push-to-talk dictation (⌃⌥V): speak your next instruction, get text.
/// Uses on-device recognition when the Mac supports it.
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, listening, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    @Published private(set) var level: Float = 0

    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    /// Made when you start talking and released when you're done, so the audio
    /// stack isn't held open the rest of the time.
    private var liveEngine: AVAudioEngine?
    private var engine: AVAudioEngine {
        if let e = liveEngine { return e }
        let e = AVAudioEngine()
        liveEngine = e
        return e
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var silenceWork: DispatchWorkItem?
    private var maxWork: DispatchWorkItem?
    private var delivered = false
    private var lastLevelAt = Date.distantPast

    func toggle() {
        switch state {
        case .idle: start()
        case .listening: stop()
        case .finishing: break
        }
    }

    func start() {
        guard state == .idle else { return }
        authorize { [weak self] ok, message in
            guard let self else { return }
            guard ok else { self.onError?(message); return }
            do { try self.begin() } catch {
                self.cleanup()
                self.onError?("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard state == .listening else { return }
        state = .finishing
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Give the recognizer a moment to finalize, then deliver what we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.deliver() }
    }

    func cancel() {
        delivered = true
        task?.cancel()
        cleanup()
    }

    // MARK: private

    private func authorize(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done(false, "Allow Speech Recognition for NotchBar in System Settings › Privacy") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    granted ? done(true, "") : done(false, "Allow Microphone access for NotchBar in System Settings › Privacy")
                }
            }
        }
    }

    private func begin() throws {
        let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec, rec.isAvailable else {
            onError?("Speech recognition isn't available right now")
            return
        }
        recognizer = rec
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true } // stays on this Mac
        req.addsPunctuation = true
        request = req
        text = ""
        delivered = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "NotchBar", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: "No microphone found"]) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            self?.meter(buffer)
        }
        engine.prepare()
        try engine.start()
        state = .listening

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    self.armSilenceStop()
                    if result.isFinal { self.deliver() }
                }
                if error != nil, self.state != .idle { self.deliver() }
            }
        }
        // Hard cap so a forgotten mic never stays open.
        let cap = DispatchWorkItem { [weak self] in self?.stop() }
        maxWork = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: cap)
    }

    /// Stop automatically after ~2s of silence once something was said.
    private func armSilenceStop() {
        silenceWork?.cancel()
        guard !text.isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        silenceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) > 0.08 else { return } // ~12 updates/s is plenty
        lastLevelAt = now
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let lvl = min(1, rms * 12)
        DispatchQueue.main.async { [weak self] in self?.level = lvl }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.finish()
        cleanup()
        if !final.isEmpty { onFinal?(final) }
    }

    private func cleanup() {
        silenceWork?.cancel(); maxWork?.cancel()
        if let e = liveEngine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
            liveEngine = nil
        }
        recognizer = nil
        request = nil
        task = nil
        state = .idle
        level = 0
    }
}
