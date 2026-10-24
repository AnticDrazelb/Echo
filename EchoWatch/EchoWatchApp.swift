import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct EchoWatchApp: App {
    @StateObject private var remote = PhoneRemote()

    var body: some Scene {
        WindowGroup {
            RemoteView()
                .environmentObject(remote)
        }
    }
}

/// Watch side of the camera remote.
@MainActor
final class PhoneRemote: NSObject, ObservableObject {
    @Published var preview: UIImage?
    @Published var mode = "Look"
    @Published var styleName = ""
    @Published var intensity: Double = 100
    @Published var isRecording = false
    @Published var cameraOpen = false
    @Published var reachable = false

    private var intensityTask: Task<Void, Never>?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func shutter() {
        send([WatchMessage.kind: WatchMessage.shutter])
    }

    func toggleRecording() {
        send([WatchMessage.kind: WatchMessage.record, WatchMessage.recording: !isRecording])
        isRecording.toggle()
        WKInterfaceDevice.current().play(isRecording ? .start : .stop)
    }

    func step(_ delta: Int) {
        send([WatchMessage.kind: delta > 0 ? WatchMessage.nextStyle : WatchMessage.previousStyle])
    }

    /// Crown turns are coalesced so the phone isn't flooded.
    func intensityChanged() {
        intensityTask?.cancel()
        let value = intensity
        intensityTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
            send([WatchMessage.kind: WatchMessage.intensity, WatchMessage.value: value])
        }
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func apply(_ message: [String: Any]) {
        switch message[WatchMessage.kind] as? String {
        case WatchMessage.state:
            mode = message[WatchMessage.mode] as? String ?? mode
            styleName = message[WatchMessage.style] as? String ?? ""
            if let v = message[WatchMessage.value] as? Double, abs(v - intensity) > 1 { intensity = v }
            isRecording = message[WatchMessage.recording] as? Bool ?? false
            cameraOpen = message[WatchMessage.cameraOpen] as? Bool ?? false
            if !cameraOpen { preview = nil }
        case WatchMessage.locked:
            // Haptic when a style locks on the phone.
            WKInterfaceDevice.current().play(.success)
        case WatchMessage.captured:
            WKInterfaceDevice.current().play(.click)
        default:
            break
        }
    }
}

extension PhoneRemote: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if !context.isEmpty { self.apply(context) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data) {
        let image = UIImage(data: data)
        Task { @MainActor in
            self.preview = image
            self.cameraOpen = true
        }
    }
}

struct RemoteView: View {
    @EnvironmentObject private var remote: PhoneRemote

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview = remote.preview, remote.cameraOpen {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            if remote.cameraOpen {
                controls
            } else {
                VStack(spacing: 8) {
                    Text("e")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text(remote.reachable ? "Open the camera in Echo on your iPhone" : "Open Echo on your iPhone")
                        .font(.system(size: 14, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .focusable()
        .digitalCrownRotation(
            $remote.intensity, from: 0, through: 100, by: 1,
            sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onChange(of: remote.intensity) { _, _ in remote.intensityChanged() }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { remote.step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                VStack(spacing: 0) {
                    Text(remote.styleName.isEmpty ? remote.mode : remote.styleName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text("\(Int(remote.intensity))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0, green: 0.478, blue: 1))
                }
                Spacer()
                Button { remote.step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            HStack(spacing: 14) {
                Button(action: remote.shutter) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 52, height: 52)
                        Circle().fill(.white).frame(width: 42, height: 42)
                        if remote.mode == "Look" {
                            Image(systemName: "camera.aperture").foregroundStyle(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(remote.mode == "Look" ? "Lock look" : "Take photo")
                if remote.mode == "Shoot" {
                    Button(action: remote.toggleRecording) {
                        RoundedRectangle(cornerRadius: remote.isRecording ? 4 : 14)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(remote.isRecording ? "Stop recording" : "Record video")
                }
            }
        }
        .padding(.bottom, 4)
    }
}
