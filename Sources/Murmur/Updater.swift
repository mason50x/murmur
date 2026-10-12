import AppKit
import CryptoKit
import Observation
import Security

/// Sparkle auto-updates. Every update is verified against the EdDSA public key in Info.plist
/// (`SUPublicEDKey`) before it's installed, and the feed itself must be signed with it too.
/// Murmur lives in the menu bar, so scheduled updates use Sparkle's gentle reminders: a menu item
/// instead of a window popping up over whatever you're doing.
///
/// Sparkle.framework isn't linked. Murmur's self-signed certificate has no Apple Team ID, so
/// library validation is off (see Murmur.entitlements); instead the framework is loaded only after
/// its signature, and everything nested in it, checks out against the certificate that signed
/// Murmur itself. A swapped-in framework never gets to run with Murmur's permissions.
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// A version found by a background check that hasn't been looked at yet.
    private(set) var pendingVersion: String?

    /// The `SPUStandardUpdaterController`, or nil if Sparkle failed verification.
    @ObservationIgnored private var controller: NSObject?
    @ObservationIgnored private var updater: NSObject? { controller?.value(forKey: "updater") as? NSObject }

    override private init() {
        super.init()
        guard Self.loadSparkle(), let type = NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type else {
            Log.info("updates disabled: Sparkle.framework failed signature verification")
            return
        }
        #if MURMUR_DEBUG_HOOKS
        // Local development builds don't check on their own; "Check for Updates…" starts it.
        let start = false
        #else
        let start = true
        #endif
        // -[SPUStandardUpdaterController initWithStartingUpdater:updaterDelegate:userDriverDelegate:]
        typealias Initializer = @convention(c) (AnyObject, Selector, Bool, AnyObject?, AnyObject?) -> Unmanaged<NSObject>
        let selector = NSSelectorFromString("initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
        let allocated = type.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        let initialize = unsafeBitCast(allocated.method(for: selector), to: Initializer.self)
        // Lives for the whole process, so the +1 references from alloc/init are simply never released.
        controller = initialize(allocated, selector, start, nil, self).takeUnretainedValue()
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { updater?.value(forKey: "automaticallyChecksForUpdates") as? Bool ?? false }
        set { updater?.setValue(newValue, forKey: "automaticallyChecksForUpdates") }
    }

    func checkForUpdates() {
        guard let controller else { return }
        #if MURMUR_DEBUG_HOOKS
        if let updater {
            typealias Start = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
            let selector = NSSelectorFromString("startUpdater:")
            _ = unsafeBitCast(updater.method(for: selector), to: Start.self)(updater, selector, nil)
        }
        #endif
        NSApp.activate()
        controller.perform(NSSelectorFromString("checkForUpdates:"), with: nil)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Verified loading

    private static func loadSparkle() -> Bool {
        guard let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
            let binary = Bundle(url: framework)?.executableURL
        else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(framework as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, sameSignerRequirement()) == errSecSuccess else { return false }
        return dlopen(binary.path, RTLD_NOW) != nil
    }

    /// "Signed by the certificate that signed this app." Nil for ad hoc development builds, which
    /// have no certificate; then only the signature's integrity is checked.
    private static func sameSignerRequirement() -> SecRequirement? {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
            SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
            SecCodeCopySigningInformation(meStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02X", $0) }.joined()
        var requirement: SecRequirement?
        SecRequirementCreateWithString("certificate leaf = H\"\(sha1)\"" as CFString, [], &requirement)
        return requirement
    }

    // MARK: - SPUStandardUserDriverDelegate

    @objc nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    nonisolated func shouldHandleShowingScheduledUpdate(_ update: NSObject, andInImmediateFocus immediateFocus: Bool)
        -> Bool
    {
        // Only show Sparkle's window right away if it's appearing at launch, not mid-dictation.
        immediateFocus
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    nonisolated func willHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: NSObject, state: NSObject) {
        let version = update.value(forKey: "displayVersionString") as? String
        MainActor.assumeIsolated {
            if !handleShowingUpdate { pendingVersion = version ?? "a new version" }
        }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    nonisolated func didReceiveUserAttention(forUpdate update: NSObject) {
        MainActor.assumeIsolated { pendingVersion = nil }
    }

    @objc(standardUserDriverWillFinishUpdateSession)
    nonisolated func willFinishUpdateSession() {
        MainActor.assumeIsolated { pendingVersion = nil }
    }
}
