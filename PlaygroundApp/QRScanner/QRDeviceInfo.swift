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

    /// OS version of the running device, e.g. `26.6.1` (the patch is dropped when zero, as
    /// Settings shows it).
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Readable model name for reports. Unknown identifiers fall back to the identifier
    /// itself, so hardware newer than this table still produces a usable row.
    static var marketingName: String {
        names[modelCode] ?? modelCode
    }

    private static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    ]
}
