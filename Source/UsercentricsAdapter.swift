// Copyright 2023-2025 Chartboost, Inc.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

import ChartboostCoreSDK
import Usercentrics
import UsercentricsUI

// WARNING for adapter developers:
// All accesses to the Usercentrics SDK APIs must be wrapped by a call to `UsercentricsCore.isReady()`.
// Usercentrics SDK will crash if its APIs are used but the SDK is not ready.

/// Chartboost Core Consent Usercentrics adapter.
@objc(CBCUsercentricsAdapter)
@objcMembers
public final class UsercentricsAdapter: NSObject, Module, ConsentAdapter {
    /// ``UsercentricsAdapter`` initialization error.
    public enum InitializationError: String, Error {
        /// Initialization failed because no `UsercentricsOptions` object was available.
        case usercentricsOptionsNotAvailable
    }

    /// A set with the latest consent info obtained from the Usercentrics SDK.
    private struct CachedConsentInfo {
        /// The latest `shouldCollectConsent` fetched value.
        var shouldCollectConsent: Bool?

        /// The latest CCPA Opt-In string fetched value.
        var ccpaOptInString: ConsentValue?

        /// The latest partner consents fetched value.
        var partnerConsents: [ConsentKey: ConsentValue]?
    }

    // MARK: - Properties

    /// The module identifier.
    public let moduleID = "usercentrics"

    /// The version of the module.
    public let moduleVersion = "1.2.20.0.0"

    /// The delegate to be notified whenever any change happens in the CMP consent info.
    /// This delegate is set by Core SDK and is an essential communication channel between Core and the CMP.
    /// Adapters should not set it themselves.
    public weak var delegate: ConsentAdapterDelegate?

    /// The settings provided when creating the Usercentrics banner.
    /// This property may be modified before the first call to ``showConsentDialog(_:from:completion:)``
    /// to customize the banner created by the adapter.
    /// Changes afterwards have no effect.
    public static var bannerSettings: BannerSettings?

    /// The Usercentrics options used to configure the Usercentrics SDK.
    private let options: UsercentricsOptions?

    /// A dictionary that maps Usercentrics templateID's to Chartboost partner IDs.
    private let partnerIDMap: [String: String]

    /// The default value for ``partnerIDMap``.
    /// This is harcoded in the adapter because of lack of backend support at the moment.
    private static let defaultPartnerIDMap = [
        "J64M6DKwx": "adcolony",
        "r7rvuoyDz": "admob",
        "IUyljv4X5": "amazon_aps",
        "fHczTMzX8": "applovin",
        "IEbRp3saT": "chartboost",
        "H17alcVo_iZ7": "fyber",
        "S1_9Vsuj-Q": "google_googlebidding",
        "ROCBK21nx": "hyprmx",
        "ykdq8J5a9MExGT": "inmobi",
        "9dchbL797": "ironsource",
        "ax0Nljnj2szF_r": "facebook",
        "E6AgqirYV": "mintegral",
        "VPSyZyTbYPSHpF": "mobilefuse",
        "HWSNU_Ll1": "pangle",
        "B1DLe54jui-X": "tapjoy",
        "hpb62D82I": "unity",
        "5bv4OvSwoXKh-G": "verve",
        "jk3jF2tpw": "vungle",
        "EMD3qUMa8": "vungle",
    ]

    /// The Usercentrics banner used to display consent dialogs.
    /// It may be customized by the user by modifying the static property ``UsercentricsAdapter.bannerSettings``.
    private lazy var banner = UsercentricsBanner(bannerSettings: Self.bannerSettings)

    /// The latest consent info fetched from the Usercentrics SDK.
    private var cachedConsentInfo = CachedConsentInfo()

    /// The observer for changes on UserDefault's consent-related keys.
    private var userDefaultsObserver: Any?

    /// Indicates whether the CMP has determined that consent should be collected from the user.
    public var shouldCollectConsent: Bool {
        cachedConsentInfo.shouldCollectConsent ?? true
    }

    /// Current user consent info as determined by the CMP.
    ///
    /// Consent info may include IAB strings, like TCF or GPP, and parsed boolean-like signals like "CCPA Opt In Sale"
    /// and partner-specific signals.
    ///
    /// Predefined consent key constants, such as ``ConsentKeys/tcf`` and ``ConsentKeys/usp``, are provided
    /// by Core. Adapters should use them when reporting the status of a common standard.
    /// Custom keys should only be used by adapters when a corresponding constant is not provided by the Core.
    ///
    /// Predefined consent value constants are also proivded, but are only applicable to non-IAB string keys, like
    /// ``ConsentKeys/ccpaOptIn`` and ``ConsentKeys/gdprConsentGiven``.
    public var consents: [ConsentKey: ConsentValue] {
        // Include per-partner consent, IAB strings, and CCPA Opt In signal
        var consents = userDefaultsIABStrings
        if let partnerConsents = cachedConsentInfo.partnerConsents {
            consents.merge(partnerConsents, uniquingKeysWith: { first, _ in first })
        }
        consents[ConsentKeys.ccpaOptIn] = cachedConsentInfo.ccpaOptInString
        return consents
    }

    // MARK: - Instantiation and Initialization

    /// Instantiates a ``UsercentricsAdapter`` module which can be passed on a call to
    /// ``ChartboostCore/initializeSDK(with:moduleObserver:)``.
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    public convenience init(options: UsercentricsOptions) {
        self.init(options: options, partnerIDMap: [:])
    }

    /// Instantiates a ``UsercentricsAdapter`` module which can be passed on a call to 
    /// ``ChartboostCore/initializeSDK(with:moduleObserver:)``.
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    /// - parameter partnerIDMap: A dictionary that maps Usercentrics templateID's to Chartboost partner IDs.
    /// A default mapping is provided by default. Information provided in this parameter is additive and overrides
    /// the default entries only in case of key collision.
    public init(
        options: UsercentricsOptions,
        partnerIDMap: [String: String] = [:]
    ) {
        self.options = options
        self.partnerIDMap = Self.defaultPartnerIDMap.merging(partnerIDMap, uniquingKeysWith: { _, second in second })
    }

    /// The designated initializer for the module.
    /// The Chartboost Core SDK will invoke this initializer when instantiating modules defined on
    /// the dashboard through reflection.
    /// - parameter credentials: A dictionary containing all the information required to initialize
    /// this module, as defined on the Chartboost Core's dashboard.
    ///
    /// - note: Modules should not perform costly operations on this initializer.
    /// Chartboost Core SDK may instantiate and discard several instances of the same module.
    /// Chartboost Core SDK keeps strong references to modules that are successfully initialized.
    public init(credentials: [String: Any]?) {
        self.options = Self.usercentricsOptions(from: credentials?["options"] as? [String: Any])
        self.partnerIDMap = credentials?["partnerIDMap"] as? [String: String] ?? [:]
    }

    /// Sets up the module to make it ready to be used.
    /// - parameter configuration: A ``ModuleConfiguration`` for configuring the module.
    /// - parameter completion: A completion handler to be executed when the module is done initializing.
    /// An error should be passed if the initialization failed, whereas `nil` should be passed if it succeeded.
    public func initialize(configuration: ModuleConfiguration, completion: @escaping (Error?) -> Void) {
        // Configure the SDK and fetch initial consent info.
        // We don't report consent changes to the delegate here since we are restoring the info from whatever the SDK has saved.
        initializeAndUpdateConsentInfo(reportingChanges: false, isFirstInitialization: true, completion: completion)
    }

    // MARK: - Consent

    /// Informs the CMP that the user has granted consent.
    /// This method should be used only when a custom consent dialog is presented to the user, thereby making the publisher
    /// responsible for the UI-side of collecting consent. In most cases ``showConsentDialog(_:from:completion:)`` should
    /// be used instead.
    /// If the CMP does not support custom consent dialogs or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter source: The source of the new consent. See the ``ConsentSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func grantConsent(source: ConsentSource, completion: @escaping (_ succeeded: Bool) -> Void) {
        log("Granting consent", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsCore.shared` is accessed and the SDK is not ready).
        initializeAndUpdateConsentInfo(reportingChanges: true) { [weak self] error in
            guard let self, error == nil else {
                completion(false)
                return
            }
            // Grant consent
            UsercentricsCore.shared.acceptAll(consentType: self.usercentricsConsentType(from: source))
            self.log("Granted consent", level: .info)

            // Fetch consent info again. Usercentrics does not report updates triggered by programmatic changes.
            self.initializeAndUpdateConsentInfo(reportingChanges: true) { error in
                completion(error == nil)
            }
        }
    }

    /// Informs the CMP that the user has denied consent.
    /// This method should be used only when a custom consent dialog is presented to the user, thereby making the publisher
    /// responsible for the UI-side of collecting consent. In most cases ``showConsentDialog(_:from:completion:)``should
    /// be used instead.
    /// If the CMP does not support custom consent dialogs or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter source: The source of the new consent. See the ``ConsentSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func denyConsent(source: ConsentSource, completion: @escaping (_ succeeded: Bool) -> Void) {
        log("Denying consent", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsCore.shared` is accessed and the SDK is not ready).
        initializeAndUpdateConsentInfo(reportingChanges: true) { [weak self] error in
            guard let self, error == nil else {
                completion(false)
                return
            }
            // Deny consent
            UsercentricsCore.shared.denyAll(consentType: self.usercentricsConsentType(from: source))
            self.log("Denied consent", level: .info)

            // Fetch consent info again. Usercentrics does not report updates triggered by programmatic changes.
            self.initializeAndUpdateConsentInfo(reportingChanges: true) { error in
                completion(error == nil)
            }
        }
    }

    /// Informs the CMP that the given consent should be reset.
    /// If the CMP does not support the `reset()` function or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func resetConsent(completion: @escaping (_ succeeded: Bool) -> Void) {
        // Reset all consents
        log("Resetting consent", level: .debug)

        // First check if Usercentrics is initialized or not, since trying to reset when not initialized leads to a crash
        UsercentricsCore.isReady(onSuccess: { [weak self] _ in
            guard let self else { return }

            // Clear cached consent info. Usercentrics does not report updates triggered by programmatic changes.
            // We do not report a consent change to the delegate here to prevent a call with "unknown" status
            // followed immediately by another one with "granted"/"denied" status once the new consent info is
            // fetched from Usercentrics in the next line.
            // We do keep track of the original cached info to trigger the proper callbacks afterwards.
            let previousConsentInfo = cachedConsentInfo
            clearCachedConsentInfo(reportingChanges: false, comparingTo: previousConsentInfo)

            // Reset Usercentrics
            UsercentricsCore.shared.clearUserSession(onSuccess: { [weak self] _ in
                guard let self else { return }
                // Usercentrics needs to be configured again after a call to `reset()`, thus we pass `isFirstInitialization` to true.
                // We pass the original consent info before it got cleared so it's used to compare against and trigger proper delegate calls
                initializeAndUpdateConsentInfo(
                    reportingChanges: true,
                    isFirstInitialization: true,
                    comparingTo: previousConsentInfo
                ) { [weak self] _ in
                    // Finish with success, since even if we failed to fetch the new info the SDK was reset.
                    self?.log("Reset consent", level: .info)
                    completion(true)
                }
            }, onError: { [weak self] error in
                self?.log("Reset failed with error: \(error)", level: .error)
                completion(false)
            })
        }, onFailure: { [weak self] _ in
            // SDK not initialized: do nothing
            self?.log("Reset skipped: Usercentrics is not initialized", level: .info)
            completion(false)
        })
    }

    /// Instructs the CMP to present a consent dialog to the user for the purpose of collecting consent.
    /// - parameter type: The type of consent dialog to present. See the ``ConsentDialogType`` documentation for more info.
    /// If the CMP does not support a given type, it should default to whatever type it does support.
    /// - parameter viewController: The view controller to present the consent dialog from.
    /// - parameter completion: This handler is called to indicate whether the consent dialog was successfully presented or not.
    /// Note that this is called at the moment the dialog is presented, **not when it is dismissed**.
    public func showConsentDialog(
        _ type: ConsentDialogType,
        from viewController: UIViewController,
        completion: @escaping (_ succeeded: Bool) -> Void
    ) {
        log("Showing \(type) consent dialog", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsBanner` is used and the SDK is not ready).
        initializeAndUpdateConsentInfo(reportingChanges: true) { [weak self] error in
            guard let self, error == nil else {
                completion(false)
                return
            }
            // Show the dialog
            switch type {
            case .concise:
                self.banner.showFirstLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("1st layer response: \(userResponse)", level: .verbose)
                }
                self.log("Showed \(type) consent dialog", level: .info)
                completion(true)
            case .detailed:
                self.banner.showSecondLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("2nd layer response: \(userResponse)", level: .verbose)
                }
                self.log("Showed \(type) consent dialog", level: .info)
                completion(true)
            default:
                self.log("Could not show consent dialog with unknown type: \(type)", level: .error)
                completion(false)
            }
        }
    }

    // MARK: - Private Func

    /// Tries to initialize the Usercentrics SDK if it's not already, and clears the cached consent info on failure.
    private func initializeAndFetchConsentInfo(
        reportingChanges: Bool,
        isFirstInitialization: Bool = false,
        comparingTo previousInfo: CachedConsentInfo? = nil,
        completion: @escaping (Result<UsercentricsReadyStatus, Error>) -> Void
    ) {
        let previousInfo = previousInfo ?? cachedConsentInfo

        // Fail if no options provided on init
        guard let options else {
            log("Failed to initialize Usercentrics: no options available.", level: .error)
            completion(.failure(InitializationError.usercentricsOptionsNotAvailable))
            return
        }

        let initializeUsercentrics = { [weak self] in
            self?.log("Initializing Usercentrics SDK", level: .debug)
            UsercentricsCore.configure(options: options)

            // Start observing consent changes and reporting updates to the delegate object
            self?.startObservingConsentChanges()
            self?.userDefaultsObserver = self?.startObservingUserDefaultsIABStrings()

            // Wait for initialization status to update
            UsercentricsCore.isReady(onSuccess: { status in
                // SDK initialized successfully
                self?.log("Initialized Usercentrics SDK successfully", level: .info)
                completion(.success(status))
            }, onFailure: { [weak self] error in
                // SDK failed to initialize
                self?.log("Failed to initialize Usercentrics SDK with error: \(error)", level: .error)

                // Clear cached consent info since it's now outdated
                self?.clearCachedConsentInfo(reportingChanges: reportingChanges, comparingTo: previousInfo)

                completion(.failure(error))
            })
        }

        if isFirstInitialization {
            // `isReady()` doesn't call its handlers if `UsercentricsCore.configure()` hasn't been called yet, so we must call
            // it first if this is a first initialization
            initializeUsercentrics()
        } else {
            // Otherwise we first check if Usercentrics SDK is already initialized
            UsercentricsCore.isReady(onSuccess: { status in
                // SDK was already initialized
                completion(.success(status))
            }, onFailure: { _ in
                // SDK not ready: try to initialize it
                initializeUsercentrics()
            })
        }
    }

    /// Tries to initialize the Usercentrics SDK if it's not already, updates the cached consent info if successful,
    /// and clears the cached consent info on failure.
    private func initializeAndUpdateConsentInfo(
        reportingChanges: Bool,
        isFirstInitialization: Bool = false,
        comparingTo previousInfo: CachedConsentInfo? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        initializeAndFetchConsentInfo(
            reportingChanges: reportingChanges,
            isFirstInitialization: isFirstInitialization,
            comparingTo: previousInfo
        ) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let status):
                self.updateCachedConsentInfo(
                    with: status,
                    reportingChanges: reportingChanges,
                    comparingTo: previousInfo ?? self.cachedConsentInfo
                )
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    /// Creates a `UsercentricsOptions` object with the dashboard information provided in a JSON dictionary.
    private static func usercentricsOptions(from dictionary: [String: Any]?) -> UsercentricsOptions? {
        guard let dictionary else {
            return nil
        }
        let loggerLevel: UsercentricsLoggerLevel
        switch dictionary["loggerLevel"] as? String {
        case "none":
            loggerLevel = .none
        case "error":
            loggerLevel = .error
        case "warning":
            loggerLevel = .warning
        case "debug":
            loggerLevel = .debug
        default:
            loggerLevel = .debug
        }
        let domains: UsercentricsDomains?
        if let domainsDict = dictionary["domains"] as? [String: Any] {
            domains = UsercentricsDomains(
                aggregatorCdnUrl: domainsDict["aggregatorCdnUrl"] as? String ?? "",
                cdnUrl: domainsDict["cdnUrl"] as? String ?? "",
                analyticsUrl: domainsDict["analyticsUrl"] as? String ?? "",
                saveConsentsUrl: domainsDict["saveConsentsUrl"] as? String ?? "",
                getConsentsUrl: domainsDict["getConsentsUrl"] as? String ?? ""
            )
        } else {
            domains = nil
        }
        return UsercentricsOptions(
            settingsId: dictionary["settingsId"] as? String ?? "",
            defaultLanguage: dictionary["defaultLanguage"] as? String ?? "en",
            version: dictionary["version"] as? String ?? "latest",
            timeoutMillis: dictionary["timeoutMillis"] as? Int64 ?? 10_000,
            loggerLevel: loggerLevel,
            ruleSetId: dictionary["ruleSetId"] as? String ?? "",
            consentMediation: dictionary["consentMediation"] as? Bool ?? false,
            domains: domains,
            initTimeoutMillis: dictionary["initTimeoutMillis"] as? Int64 ?? 10_000
        )
    }

    /// Maps a `ConsentSource` value to a corresponding `UsercentricsConsentType` value.
    private func usercentricsConsentType(from coreConsentSource: ConsentSource) -> UsercentricsConsentType {
        switch coreConsentSource {
        case .user:
            return .explicit_
        case .developer:
            return .implicit
        default:
            return .implicit
        }
    }

    /// Makes the adapter begin to receive consent updates from the Usercentrics SDK.
    private func startObservingConsentChanges() {
        log("Starting to observe consent changes", level: .debug)

        UsercentricsEvent.shared.onConsentUpdated { [weak self] payload in
            guard let self else { return }

            self.log("Received Usercentrics consent update", level: .info)
            self.log("Update payload:\n\(payload)", level: .verbose)

            // We discard the payload and just pull all the info directly from the SDK.
            // The result should be the same, we do this to simplify our implementation and prevent
            // data from getting out of sync.
            self.initializeAndUpdateConsentInfo(reportingChanges: true, completion: { _ in })
        }
    }

    /// Updates the cached consent info and reports updates to the indicated delegate.
    private func updateCachedConsentInfo(
        with status: UsercentricsReadyStatus,
        reportingChanges: Bool,
        comparingTo previousInfo: CachedConsentInfo
    ) {
        log("Updating consent info", level: .debug)
        let gatedDelegate = reportingChanges ? delegate : nil

        // Should Collect Consent
        cachedConsentInfo.shouldCollectConsent = status.shouldCollectConsent

        // CCPA Opt-In String
        let uspData = UsercentricsCore.shared.getUSPData()
        let newCCPAString: ConsentValue?
        if let ccpaOptedOut = uspData.optedOut {
            newCCPAString = ccpaOptedOut.boolValue ? ConsentValues.denied : ConsentValues.granted
        } else {
            newCCPAString = nil
        }
        cachedConsentInfo.ccpaOptInString = newCCPAString
        if previousInfo.ccpaOptInString != newCCPAString {
            gatedDelegate?.onConsentChange(key: ConsentKeys.ccpaOptIn)
        }

        // Partner Consents
        cachedConsentInfo.partnerConsents = [:]
        for consent in status.consents {
            let key = partnerIDMap[consent.templateId] ?? consent.templateId    // if no mapping we use Usercentrics templateId directly
            cachedConsentInfo.partnerConsents?[key] = consent.status ? ConsentValues.granted : ConsentValues.denied
        }
        if previousInfo.partnerConsents != cachedConsentInfo.partnerConsents {
            // Report changes to existing or new entries
            for (partnerID, status) in cachedConsentInfo.partnerConsents ?? [:]
                where previousInfo.partnerConsents?[partnerID] != status {
                gatedDelegate?.onConsentChange(key: partnerID)
            }
            // Report changes for deleted entries
            for (partnerID, _) in previousInfo.partnerConsents ?? [:]
                where cachedConsentInfo.partnerConsents?[partnerID] == nil {
                gatedDelegate?.onConsentChange(key: partnerID)
            }
        }
    }

    /// Clears the adapter internal cache and reports updates to the delegate.
    private func clearCachedConsentInfo(reportingChanges: Bool, comparingTo previousInfo: CachedConsentInfo) {
        log("Clearing consent info", level: .debug)
        let gatedDelegate = reportingChanges ? delegate : nil

        // Should Collect Consent
        cachedConsentInfo.shouldCollectConsent = nil

        // CCPA Opt-In String
        cachedConsentInfo.ccpaOptInString = nil
        if previousInfo.ccpaOptInString != nil {
            gatedDelegate?.onConsentChange(key: ConsentKeys.ccpaOptIn)
        }

        // Per-vendor consent
        cachedConsentInfo.partnerConsents = nil
        if let gatedDelegate, let previousPartnerConsentStatus = previousInfo.partnerConsents {
            for partnerID in previousPartnerConsentStatus.keys {
                gatedDelegate.onConsentChange(key: partnerID)
            }
        }
    }
}
