// Copyright 2022-2023 Chartboost, Inc.
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
public final class UsercentricsAdapter: NSObject, ConsentAdapter {

    /// ``UsercentricsAdapter`` initialization error.
    public enum InitializationError: String, Error {
        /// Initialization failed because no `UsercentricsOptions` object was available.
        case usercentricsOptionsNotAvailable
    }

    /// A set with the latest consent info obtained from the Usercentrics SDK.
    private struct CachedConsentInfo {
        /// The latest `shouldCollectConsent` fetched value.
        var shouldCollectConsent: Bool?

        /// The latest `consentStatus` fetched value.
        var consentStatus: ConsentStatus?

        /// The latest TCF string fetched value.
        var tcfString: String?

        /// The latest USP string fetched value.
        var uspString: String?

        /// The latest CCPA Opt-In string fetched value.
        var ccpaOptInString: ConsentValue?
    }

    // MARK: - Properties

    /// The module identifier.
    public let moduleID = "usercentrics"

    /// The version of the module.
    public let moduleVersion = "0.2.8.0.1"

    /// The delegate to be notified whenever any change happens in the CMP consent status.
    /// This delegate is set by Core SDK and is an essential communication channel between Core and the CMP.
    /// Adapters should not set it themselves.
    public weak var delegate: ConsentAdapterDelegate?

    /// The default value for `chartboostCoreDPSName` when none is provided.
    public static var defaultChartboostCoreDPSName = "ChartboostCore"

    /// The settings provided when creating the Usercentrics banner.
    /// This property may be modified before the first call to ``showConsentDialog(_:from:completion:)`` to customize the banner created by the adapter.
    /// Changes afterwards have no effect.
    public static var bannerSettings: BannerSettings?

    /// The name of the Usercentrics Data Processing Service (DPS) defined in the Usercentrics dashboard for the Chartboost Core SDK.
    private let chartboostCoreDPSName: String

    /// The Usercentrics options used to configure the Usercentrics SDK.
    private let options: UsercentricsOptions?

    /// The Usercentrics banner used to display consent dialogs.
    /// It may be customized by the user by modifying the static property ``UsercentricsAdapter.bannerSettings``.
    private lazy var banner = UsercentricsBanner(bannerSettings: Self.bannerSettings)

    /// The latest consent info fetched from the Usercentrics SDK.
    private var cachedConsentInfo = CachedConsentInfo()

    /// Indicates whether the CMP has determined that consent should be collected from the user.
    public var shouldCollectConsent: Bool {
        cachedConsentInfo.shouldCollectConsent ?? true
    }

    /// The current consent status determined by the CMP.
    public var consentStatus: ConsentStatus {
        cachedConsentInfo.consentStatus ?? .unknown
    }

    /// Detailed consent status for each consent standard, as determined by the CMP.
    ///
    /// Predefined consent standard constants, such as ``ConsentStandard/usp`` and ``ConsentStandard/tcf``, are provided
    /// by Core. Adapters should use them when reporting the status of a common standard.
    /// Custom standards should only be used by adapters when a corresponding constant is not provided by the Core.
    ///
    /// While Core also provides consent value constants, these are only applicable for the ``ConsentStandard/ccpa`` and
    /// ``ConsentStandard/gdpr`` standards. For other standards a custom value should be provided (e.g. a IAB TCF string
    /// for ``ConsentStandard/tcf``).
    public var consents: [ConsentStandard : ConsentValue] {
        var consents: [ConsentStandard: ConsentValue] = [:]
        consents[.tcf] = cachedConsentInfo.tcfString.map(ConsentValue.init(stringLiteral:))
        consents[.usp] = cachedConsentInfo.uspString.map(ConsentValue.init(stringLiteral:))
        consents[.ccpaOptIn] = cachedConsentInfo.ccpaOptInString
        return consents
    }

    // MARK: - Instantiation and Initialization

    /// Instantiates a ``UsercentricsAdapter`` module which can be passed on a call to ``ChartboostCore/initializeSDK(with:moduleObserver:)``.
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    public convenience init(options: UsercentricsOptions) {
        self.init(options: options, chartboostCoreDPSName: UsercentricsAdapter.defaultChartboostCoreDPSName)
    }

    /// Instantiates a ``UsercentricsAdapter`` module which can be passed on a call to ``ChartboostCore/initializeSDK(with:moduleObserver:)``.
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    /// - parameter chartboostCoreDPSName: The name for the Chartboost Core DPS that matches the one set on the Usercentrics dashboard.
    public init(options: UsercentricsOptions, chartboostCoreDPSName: String = UsercentricsAdapter.defaultChartboostCoreDPSName) {
        self.options = options
        self.chartboostCoreDPSName = chartboostCoreDPSName
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
    public init(credentials: [String : Any]?) {
        self.options = Self.usercentricsOptions(from: credentials?["options"] as? [String: Any])
        self.chartboostCoreDPSName = credentials?["coreDpsName"] as? String ?? Self.defaultChartboostCoreDPSName
    }

    /// Sets up the module to make it ready to be used.
    /// - parameter configuration: A ``ModuleInitializationConfiguration`` for configuring the module.
    /// - parameter completion: A completion handler to be executed when the module is done initializing.
    /// An error should be passed if the initialization failed, whereas `nil` should be passed if it succeeded.
    public func initialize(configuration: ModuleInitializationConfiguration, completion: @escaping (Error?) -> Void) {
        // Configure the SDK and fetch initial consent status.
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
    /// - parameter source: The source of the new consent. See the ``ConsentStatusSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func grantConsent(source: ConsentStatusSource, completion: @escaping (_ succeeded: Bool) -> Void) {
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
    /// - parameter source: The source of the new consent. See the ``ConsentStatusSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func denyConsent(source: ConsentStatusSource, completion: @escaping (_ succeeded: Bool) -> Void) {
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
        UsercentricsCore.reset()

        // Clear cached consent info. Usercentrics does not report updates triggered by programmatic changes.
        // We do not report a consent change to the delegate here to prevent a call with "unknown" status
        // followed immediately by another one with "granted"/"denied" status once the new consent info is
        // fetched from Usercentrics in the next line.
        // We do keep track of the original cached info to trigger the proper callbacks afterwards.
        let previousConsentInfo = cachedConsentInfo
        clearCachedConsentInfo(reportingChanges: false, comparingTo: previousConsentInfo)

        // Usercentrics needs to be configured again after a call to `reset()`, thus we pass `isFirstInitialization` to true.
        // We pass the original consent info before it got cleared so it's used to compare against and trigger proper delegate calls
        initializeAndUpdateConsentInfo(reportingChanges: true, isFirstInitialization: true, comparingTo: previousConsentInfo) { [weak self] _ in
            // Finish with success, since even if we failed to fetch the new info the SDK was reset.
            self?.log("Reset consent", level: .info)
            completion(true)
        }
    }

    /// Instructs the CMP to present a consent dialog to the user for the purpose of collecting consent.
    /// - parameter type: The type of consent dialog to present. See the ``ConsentDialogType`` documentation for more info.
    /// If the CMP does not support a given type, it should default to whatever type it does support.
    /// - parameter viewController: The view controller to present the consent dialog from.
    /// - parameter completion: This handler is called to indicate whether the consent dialog was successfully presented or not.
    /// Note that this is called at the moment the dialog is presented, **not when it is dismissed**.
    public func showConsentDialog(_ type: ConsentDialogType, from viewController: UIViewController, completion: @escaping (_ succeeded: Bool) -> Void) {
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
                    self?.log("1st layer response: \(userResponse)", level: .trace)
                }
                self.log("Showed \(type) consent dialog", level: .info)
                completion(true)
            case .detailed:
                self.banner.showSecondLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("2nd layer response: \(userResponse)", level: .trace)
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
        return UsercentricsOptions(
            settingsId: dictionary["settingsId"] as? String ?? "",
            defaultLanguage: dictionary["defaultLanguage"] as? String ?? "en",
            version: dictionary["version"] as? String ?? "latest",
            timeoutMillis: dictionary["timeoutMillis"] as? Int64 ?? 5_000,
            loggerLevel: loggerLevel,
            ruleSetId: dictionary["ruleSetId"] as? String ?? "",
            consentMediation: dictionary["consentMediation"] as? Bool ?? false
        )
    }

    /// Maps a `ConsentStatusSource` value to a corresponding `UsercentricsConsentType` value.
    private func usercentricsConsentType(from coreConsentStatusSource: ConsentStatusSource) -> UsercentricsConsentType {
        switch coreConsentStatusSource {
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
            self.log("Update payload:\n\(payload)", level: .trace)

            // We discard the payload and just pull all the info directly from the SDK.
            // The result should be the same, we do this to simplify our implementation and prevent
            // data from getting out of sync.
            self.initializeAndUpdateConsentInfo(reportingChanges: true, completion: { _ in })
        }
    }

    /// Updates the cached consent info and reports updates to the indicated delegate.
    private func updateCachedConsentInfo(with status: UsercentricsReadyStatus, reportingChanges: Bool, comparingTo previousInfo: CachedConsentInfo) {
        log("Updating consent info", level: .debug)
        let gatedDelegate = reportingChanges ? delegate : nil

        // Should Collect Consent
        cachedConsentInfo.shouldCollectConsent = status.shouldCollectConsent

        // Consent Status
        let newConsentStatus: ConsentStatus?
        if let coreDPS = status.consents.first(where: { $0.dataProcessor == chartboostCoreDPSName }) {
            newConsentStatus = coreDPS.status ? .granted : .denied
        } else {
            log("ChartboostCore DPS not found in payload, expected one named '\(chartboostCoreDPSName)'", level: .error)
            newConsentStatus = nil
        }
        cachedConsentInfo.consentStatus = newConsentStatus
        if previousInfo.consentStatus != newConsentStatus {
            gatedDelegate?.onConsentStatusChange(consentStatus)
        }

        // TCF string
        UsercentricsCore.shared.getTCFData { [weak self] tcfData in
            guard let self else { return }
            let newTCFString = tcfData.tcString.isEmpty ? nil : tcfData.tcString
            self.cachedConsentInfo.tcfString = newTCFString
            if previousInfo.tcfString != newTCFString {
                gatedDelegate?.onConsentChange(standard: .tcf, value: newTCFString.map(ConsentValue.init(stringLiteral:)))
            }
        }

        // USP String
        let uspData = UsercentricsCore.shared.getUSPData()
        let newUSPString = uspData.uspString.isEmpty ? nil : uspData.uspString
        cachedConsentInfo.uspString = newUSPString
        if previousInfo.uspString != newUSPString {
            gatedDelegate?.onConsentChange(standard: .usp, value: newUSPString.map(ConsentValue.init(stringLiteral:)))
        }

        // CCPA Opt-In String
        let newCCPAString: ConsentValue?
        if let ccpaOptedOut = uspData.optedOut {
            newCCPAString = ccpaOptedOut.boolValue ? .denied : .granted
        } else {
            newCCPAString = nil
        }
        cachedConsentInfo.ccpaOptInString = newCCPAString
        if previousInfo.ccpaOptInString != newCCPAString {
            gatedDelegate?.onConsentChange(standard: .ccpaOptIn, value: newCCPAString)
        }
    }

    /// Clears the adapter internal cache and reports updates to the delegate.
    private func clearCachedConsentInfo(reportingChanges: Bool, comparingTo previousInfo: CachedConsentInfo) {
        log("Clearing consent info", level: .debug)
        let gatedDelegate = reportingChanges ? delegate : nil

        // Should Collect Consent
        cachedConsentInfo.shouldCollectConsent = nil

        // Consent Status
        cachedConsentInfo.consentStatus = nil
        if previousInfo.consentStatus != nil {
            gatedDelegate?.onConsentStatusChange(consentStatus)
        }

        // TCF string
        cachedConsentInfo.tcfString = nil
        if previousInfo.tcfString != nil {
            gatedDelegate?.onConsentChange(standard: .tcf, value: nil)
        }

        // USP String
        cachedConsentInfo.uspString = nil
        if previousInfo.uspString != nil {
            gatedDelegate?.onConsentChange(standard: .usp, value: nil)
        }

        // CCPA Opt-In String
        cachedConsentInfo.ccpaOptInString = nil
        if previousInfo.ccpaOptInString != nil {
            gatedDelegate?.onConsentChange(standard: .ccpaOptIn, value: nil)
        }
    }
}
