import Foundation

/// The hardware model identifier of the device a capture was taken on — `iPhone17,1` rather
/// than the marketing name, since that is what `uname` reports and it needs no lookup table
/// to stay correct on hardware released after this build.
///
/// Stored on every capture so that reports AirDropped off one device still say which device
/// produced them: a corner deviation between two captures means something quite different
/// when they came from two different phones.
///
/// `nonisolated` because records are built on the capture engine's video queue.
nonisolated enum QRDeviceInfo {

    /// Resolved once — `uname` cannot change while the process is alive.
    static let modelCode: String = {
        // On the Simulator `uname` reports the host Mac, so the simulated device's own
        // identifier has to come from the environment instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (sim)"
        }

        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine.isEmpty ? "unknown" : machine
    }()
}
