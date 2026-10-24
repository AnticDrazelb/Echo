import Foundation

/// Messages exchanged between the iPhone camera and the Watch remote.
enum WatchMessage {
    static let kind = "kind"

    // Phone → Watch
    static let state = "state"        // + mode, style, intensity, recording
    static let locked = "locked"      // a look was just locked (haptic)
    static let captured = "captured"  // photo taken / video saved

    // Watch → Phone
    static let shutter = "shutter"    // tap: photo (Shoot) or lock (Look)
    static let record = "record"      // + on: Bool, start/stop video
    static let intensity = "intensity" // + value: Double 0...100
    static let nextStyle = "nextStyle"
    static let previousStyle = "previousStyle"

    static let mode = "mode"
    static let style = "style"
    static let value = "value"
    static let recording = "recording"
    static let cameraOpen = "cameraOpen"
}
