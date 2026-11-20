import Foundation

/// The native side of Rainwire's window protocol (Bridge/apc/wm_bridge.c): it answers the board's Query and queues the
/// Rainwire:WM messages for us. Port of the Windows client's `RainwireWm/WmNative.cs`; macOS links the bridge
/// statically, so the functions are always there (no missing-export fallback), and they're called through the
/// bridging header (native_bridge.h) like the TRACE ones.
enum WmNative {
    /// Switches the protocol on in the native bridge.
    static func enable(_ on: Bool) {
        native_wm_set_enabled(on ? 1 : 0)
    }

    /// The oldest queued message into buffer: its length, 0 when none, -1 when buffer is too small.
    static func poll(_ buffer: inout [CChar]) -> Int {
        let count = Int32(buffer.count)
        return Int(buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            native_wm_poll(buf.baseAddress, count)
        })
    }

    /// Bytes to the board, on the one connection.
    static func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        _ = NativeBridge.shared.sendData(Data(bytes))
    }
}
