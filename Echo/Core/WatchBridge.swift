import CoreImage
import Foundation
import UIKit
import WatchConnectivity

/// Implemented by the camera screen while it's open.
@MainActor
protocol WatchRemote: AnyObject {
    func watchShutter()
    func watchRecord(_ on: Bool)
    func watchIntensity(_ value: Float)
    func watchStep(_ delta: Int)
}

/// Phone side of the Apple Watch remote: streams small preview frames and
/// camera state to the watch, and forwards its commands to the camera.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()

    @MainActor weak var remote: WatchRemote?
    private let lock = NSLock()
    private var lastFrame = Date.distantPast
    private var sending = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var canSend: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
            && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

    // MARK: Phone → Watch

    func sendState(mode: String, style: String?, intensity: Float, recording: Bool, cameraOpen: Bool = true) {
        guard canSend else { return }
        let payload: [String: Any] = [
            WatchMessage.kind: WatchMessage.state,
            WatchMessage.mode: mode,
            WatchMessage.style: style ?? "",
            WatchMessage.value: Double(intensity * 100),
            WatchMessage.recording: recording,
            WatchMessage.cameraOpen: cameraOpen,
        ]
        // Context survives the watch app not running; messages are live.
        try? WCSession.default.updateApplicationContext(payload)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    func sendEvent(_ kind: String) {
        guard canSend, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchMessage.kind: kind], replyHandler: nil, errorHandler: nil)
    }

    /// Called from the camera's video queue with every styled frame; sends
    /// a ~200px JPEG at most 5 times a second while the watch is reachable.
    func offerFrame(_ image: CIImage) {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        lock.lock()
        let due = !sending && Date().timeIntervalSince(lastFrame) > 0.2
        if due { sending = true; lastFrame = Date() }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { self.lock.lock(); self.sending = false; self.lock.unlock() }
            guard let cg = RenderEngine.shared.cgImage(image.fitting(longSide: 220)),
                  let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.55)
            else { return }
            WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Watch → Phone

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let kind = message[WatchMessage.kind] as? String else { return }
        let value = message[WatchMessage.value] as? Double
        let on = message[WatchMessage.recording] as? Bool
        Task { @MainActor in
            guard let remote = self.remote else { return }
            switch kind {
            case WatchMessage.shutter: remote.watchShutter()
            case WatchMessage.record: remote.watchRecord(on ?? false)
            case WatchMessage.intensity: remote.watchIntensity(Float((value ?? 100) / 100))
            case WatchMessage.nextStyle: remote.watchStep(1)
            case WatchMessage.previousStyle: remote.watchStep(-1)
            default: break
            }
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
