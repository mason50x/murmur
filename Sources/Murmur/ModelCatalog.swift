import Foundation
import FluidAudio

/// The English speech models Murmur can run. Both are NVIDIA Parakeet 0.6B derivatives with
/// punctuation and capitalization, running on the Neural Engine via FluidAudio.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    /// Parakeet Unified EN 0.6B, full-attention offline encoder (int8).
    case unified
    /// Phonon-2: a quantization-aware re-training of Parakeet TDT v3 with a sparse encoder.
    case phonon2

    var id: String { rawValue }

    var name: String {
        switch self {
        case .unified: "Parakeet Unified"
        case .phonon2: "Phonon-2"
        }
    }

    var tier: String {
        switch self {
        case .unified: "Best accuracy"
        case .phonon2: "Light & fast"
        }
    }

    var summary: String {
        switch self {
        case .unified: "The most accurate English model. Best on Macs with 16 GB of memory or more."
        case .phonon2: "Nearly as accurate, half the memory, and the fastest on the Neural Engine. Best on 8 GB Macs."
        }
    }

    /// Approximate download, for display.
    var downloadMB: Int {
        switch self {
        case .unified: 610
        case .phonon2: 360
        }
    }

    /// LibriSpeech test-clean word error rate (FluidAudio benchmarks, M5 Pro).
    var wordErrorRate: String {
        switch self {
        case .unified: "2.1%"
        case .phonon2: "2.5%"
        }
    }

    var repo: Repo {
        switch self {
        case .unified: .parakeetUnified
        case .phonon2: .phonon2
        }
    }

    /// Where FluidAudio caches this model's files.
    var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(repo.folderName, isDirectory: true)
    }

    var isDownloaded: Bool {
        switch self {
        case .unified:
            let fm = FileManager.default
            return [
                ModelNames.ParakeetUnified.offlineEncoderInt8File,
                ModelNames.ParakeetUnified.decoderFile,
                ModelNames.ParakeetUnified.jointDecisionFile,
                ModelNames.ParakeetUnified.vocab,
            ].allSatisfy { fm.fileExists(atPath: cacheDirectory.appendingPathComponent($0).path) }
        case .phonon2:
            return AsrModels.modelsExist(at: cacheDirectory, version: .phonon2)
        }
    }

    /// Frees the disk space this model uses.
    func deleteFiles() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// The model the user picked, or nil before onboarding has chosen one.
    static var selected: SpeechModel? {
        get { UserDefaults.standard.string(forKey: "model").flatMap(SpeechModel.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "model") }
    }
}

/// The parts of this Mac that decide which model fits best.
struct DeviceProfile: Sendable {
    let chip: String
    let memoryGB: Int
    let freeDiskGB: Double

    static let current = DeviceProfile()

    init(chip: String, memoryGB: Int, freeDiskGB: Double) {
        self.chip = chip
        self.memoryGB = memoryGB
        self.freeDiskGB = freeDiskGB
    }

    private init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer)
        chip = brand.isEmpty ? "Apple silicon" : brand
        memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        freeDiskGB = Double(free) / 1_000_000_000
    }

    /// 16 GB+ gets the most accurate model; 8 GB Macs (or a nearly full disk) get the lighter one,
    /// which leaves more memory for everything else and is faster on older Neural Engines.
    var recommended: SpeechModel {
        memoryGB >= 16 && freeDiskGB > 2 ? .unified : .phonon2
    }

    var description: String { "\(chip) with \(memoryGB) GB of memory" }
}
