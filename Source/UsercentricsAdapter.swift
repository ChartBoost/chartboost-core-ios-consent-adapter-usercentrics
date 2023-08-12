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

    /// UsercentricsAdapter initialization error.
    public enum InitializationError: String, Error {
        /// Initialization failed because no `UsercentricsOptions` object was available.
        case usercentricsOptionsNotAvailable
    }

    /// The module identifier.
    public let moduleID = "usercentrics"

    /// The version of the module.
    public let moduleVersion = "0.2.8.0.0"

    /// The delegate to be notified whenever any change happens in the CMP consent status.
    /// This delegate is set by Core SDK and is an essential communication channel between Core and the CMP.
    /// Adapters should not set it themselves.
    public weak var delegate: ConsentAdapterDelegate?

    /// The name of the Usercentrics Data Processing Service (DPS) defined in the Usercentrics dashboard for the Chartboost Core SDK.
    let chartboostCoreDPSName: String

    /// The Usercentrics options used to configure the Usercentrics SDK.
    let options: UsercentricsOptions?

    /// The default value for `chartboostCoreDPSName` when none is provided.
    public static var defaultChartboostCoreDPSName = "ChartboostCore"

    /// The settings provided when creating the Usercentrics banner.
    /// This property may be modified before the first call to ``showConsentDialog()`` to customize the banner created by the adapter.
    /// Changes afterwards have no effect.
    public static var bannerSettings: BannerSettings?

    /// The latest shouldCollectConsent fetched value.
    private var cachedShouldCollectConsent: Bool?

    /// The latest consentStatus fetched value.
    private var cachedConsentStatus: ConsentStatus?

    /// The latest TCF string fetched value.
    private var cachedTCFString: String?

    /// The latest USP string fetched value.
    private var cachedUSPString: String?

    /// The latest CCPA Opt-In string fetched value.
    private var cachedCCPAOptInString: ConsentValue?

    /// The Usercentrics banner used to display consent dialogs.
    /// It may be customized by the user by modifying the static property ``UsercentricsAdapter.bannerSettings``.
    private lazy var banner = UsercentricsBanner(bannerSettings: Self.bannerSettings)

    /// Instantiates a UsercentricsAdapter module which can be passed on a call to ``ChartboostCore.initializeSDK()`
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    public convenience init(options: UsercentricsOptions) {
        self.init(options: options, chartboostCoreDPSName: UsercentricsAdapter.defaultChartboostCoreDPSName)
    }

    /// Instantiates a UsercentricsAdapter module which can be passed on a call to ``ChartboostCore.initializeSDK()`
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
    /// - completion: A completion handler to be executed when the module is done initializing.
    /// An error should be passed if the initialization failed, whereas `nil` should be passed if it succeeded.
    public func initialize(completion: @escaping (Error?) -> Void) {
        // Configure the SDK and fetch initial consent status.
        // We don't report consent changes to the delegate here since we are restoring the info from whatever the SDK has saved.
        initializeAndUpdateConsentInfo(delegate: nil, completion: completion)
    }

    /// Indicates whether the CMP has determined that consent should be collected from the user.
    public var shouldCollectConsent: Bool {
        cachedShouldCollectConsent ?? true
    }

    /// The current consent status determined by the CMP.
    public var consentStatus: ConsentStatus {
        cachedConsentStatus ?? .unknown
    }

    /// Detailed consent status for each consent standard, as determined by the CMP.
    ///
    /// Predefined consent standard constants, such as ``ConsentStandard.usp`` and ``ConsentStandard.tcf``, are provided
    /// by Core. Adapters should use them when reporting the status of a common standard.
    /// Custom standards should only be used by adapters when a corresponding constant is not provided by the Core.
    ///
    /// While Core also provides consent value constants, these are only applicable for the ``ConsentStandard.ccpa`` and
    /// ``ConsentStandard.gdpr`` standards. For other standards a custom value should be provided (e.g. a IAB TCF string
    /// for ``ConsentStandard.tcf``).
    public var consents: [ConsentStandard : ConsentValue] {
        var consents: [ConsentStandard: ConsentValue] = [:]
        consents[.tcf] = cachedTCFString.map(ConsentValue.init(stringLiteral:))
        consents[.usp] = cachedUSPString.map(ConsentValue.init(stringLiteral:))
        consents[.ccpaOptIn] = cachedCCPAOptInString
        return consents
    }

    /// Informs the CMP that the user has granted consent.
    /// This method should be used only when a custom consent dialog is presented to the user, thereby making the publisher
    /// responsible for the UI-side of collecting consent. In most cases ``showConsentDialog(_:from:completion:)``should
    /// be used instead.
    /// If the CMP does not support custom consent dialogs or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter source: The source of the new consent. See the ``ConsentStatusSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func grantConsent(source: ConsentStatusSource, completion: @escaping (Bool) -> Void) {
        log("Granting consent", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsCore.shared` is accessed and the SDK is not ready).
        initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate: delegate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Grant consent
                UsercentricsCore.shared.acceptAll(consentType: self.usercentricsConsentType(from: source))
                self.log("Granted consent", level: .info)

                // Fetch consent info again. Usercentrics does not report updates triggered by programmatic changes.
                self.initializeAndUpdateConsentInfo(delegate: self.delegate) { error in
                    completion(error == nil)
                }
            case .failure:
                completion(false)
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
    public func denyConsent(source: ConsentStatusSource, completion: @escaping (Bool) -> Void) {
        log("Denying consent", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsCore.shared` is accessed and the SDK is not ready).
        initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate: delegate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Deny consent
                UsercentricsCore.shared.denyAll(consentType: self.usercentricsConsentType(from: source))
                self.log("Denied consent", level: .info)

                // Fetch consent info again. Usercentrics does not report updates triggered by programmatic changes.
                self.initializeAndUpdateConsentInfo(delegate: self.delegate) { error in
                    completion(error == nil)
                }
            case .failure:
                completion(false)
            }
        }
    }

    /// Informs the CMP that the given consent should be reset.
    /// If the CMP does not support the reset() function or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func resetConsent(completion: @escaping (Bool) -> Void) {
        // Reset all consents
        log("Resetting consent", level: .debug)
        UsercentricsCore.reset()

        // Clear cached consent info. Usercentrics does not report updates triggered by programmatic changes.
        // We do not report a consent change to the delegate here to prevent a call with "unknown" status
        // followed immediately by another one with "granted"/"denied" status once the new consent info is
        // fetched from Usercentrics in the next line.
        // We do keep track of the callbacks with a delegate proxy and invoke them later if we fail to fetch
        // the new consent info.
        let delegateProxy = ConsentAdapterDelegateDelayProxy()
        clearCachedConsentInfo(delegate: delegateProxy)

        // Usercentrics needs to be configured again after a call to reset()
        // We do not pass a delegate here because we update the delegate later using the proxy if needed.
        initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate: nil) { [weak self] result in
            switch result {
            case .success(let status):
                self?.updateCachedConsentInfo(with: status, delegate: self?.delegate)
            case .failure:
                // Report changes to a "unknown" consent info state if we failed to fetch the new info from Usercentrics
                delegateProxy.relayReceivedCallbacks(to: self?.delegate)
            }
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
    public func showConsentDialog(_ type: ConsentDialogType, from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        log("Showing \(type) consent dialog", level: .debug)

        // Initialize Usercentrics if needed (an exception is raised if `UsercentricsBanner` is used and the SDK is not ready).
        initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate: delegate) { [weak self] result in
            guard case .success = result else {
                completion(false)
                return
            }
            // Show the dialog
            switch type {
            case .concise:
                self?.banner.showFirstLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("1st layer response: \(userResponse)", level: .trace)
                }
                self?.log("Showed \(type) consent dialog", level: .info)
                completion(true)
            case .detailed:
                self?.banner.showSecondLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("2nd layer response: \(userResponse)", level: .trace)
                }
                self?.log("Showed \(type) consent dialog", level: .info)
                completion(true)
            default:
                self?.log("Could not show consent dialog with unknown type: \(type)", level: .error)
                completion(false)
            }
        }
    }

    /// Tries to initialize the Usercentrics SDK if it's not already, and clears the cached consent info on failure.
    private func initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate delegate: ConsentAdapterDelegate?, completion: @escaping (Result<UsercentricsReadyStatus, Error>) -> Void) {
        // Fail if no options provided on init
        guard let options else {
            log("Failed to initialize Usercentrics: no options available.", level: .error)
            completion(.failure(InitializationError.usercentricsOptionsNotAvailable))
            return
        }

        // Check if Usercentrics SDK is already initialized
        UsercentricsCore.isReady(onSuccess: { status in
            // SDK was already initialized
            completion(.success(status))
        }, onFailure: { [weak self] error in
            // SDK not ready: try to initialize it
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
                self?.clearCachedConsentInfo(delegate: delegate)

                completion(.failure(error))
            })
        })
    }

    /// Tries to initialize the Usercentrics SDK if it's not already, updates the cached consent info if successful,
    /// and clears the cached consent info on failure.
    private func initializeAndUpdateConsentInfo(delegate: ConsentAdapterDelegate?, completion: @escaping (Error?) -> Void) {
        initializeAndFetchConsentInfo(clearingConsentOnFailureWithDelegate: delegate) { [weak self] result in
            switch result {
            case .success(let status):
                self?.updateCachedConsentInfo(with: status, delegate: delegate)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    /// Creates a UsercentricsOptions object with the dashboard information provided in a JSON dictionary.
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
            self.initializeAndUpdateConsentInfo(delegate: self.delegate, completion: { _ in })
        }
    }

    /// Updates the cached consent info and reports updates to the indicated delegate.
    private func updateCachedConsentInfo(with status: UsercentricsReadyStatus, delegate: ConsentAdapterDelegate?) {
        log("Updating consent info", level: .debug)

        // Should Collect Consent
        cachedShouldCollectConsent = status.shouldCollectConsent

        // Consent Status
        let newConsentStatus: ConsentStatus?
        if let coreDPS = status.consents.first(where: { $0.dataProcessor == chartboostCoreDPSName }) {
            newConsentStatus = coreDPS.status ? .granted : .denied
        } else {
            log("ChartboostCore DPS not found in payload, expected one named '\(chartboostCoreDPSName)'", level: .error)
            newConsentStatus = nil
        }
        if cachedConsentStatus != newConsentStatus {
            cachedConsentStatus = newConsentStatus
            delegate?.onConsentStatusChange(consentStatus)
        }

        // TCF string
        UsercentricsCore.shared.getTCFData { [weak self] tcfData in
            guard let self else { return }
            let newTCFString = tcfData.tcString.isEmpty ? nil : tcfData.tcString
            if self.cachedTCFString != newTCFString {
                self.cachedTCFString = newTCFString
                delegate?.onConsentChange(standard: .tcf, value: newTCFString.map(ConsentValue.init(stringLiteral:)))
            }
        }

        // USP String
        let uspData = UsercentricsCore.shared.getUSPData()
        let newUSPString = uspData.uspString.isEmpty ? nil : uspData.uspString
        if cachedUSPString != newUSPString {
            cachedUSPString = newUSPString
            delegate?.onConsentChange(standard: .usp, value: newUSPString.map(ConsentValue.init(stringLiteral:)))
        }

        // CCPA Opt-In String
        let newCCPAString: ConsentValue?
        if let ccpaOptedOut = uspData.optedOut {
            newCCPAString = ccpaOptedOut.boolValue ? .denied : .granted
        } else {
            newCCPAString = nil
        }
        if cachedCCPAOptInString != newCCPAString {
            cachedCCPAOptInString = newCCPAString
            delegate?.onConsentChange(standard: .ccpaOptIn, value: newCCPAString)
        }
    }

    /// Clears the adapter internal cache and reports updates to the delegate.
    private func clearCachedConsentInfo(delegate: ConsentAdapterDelegate?) {
        log("Clearing consent info", level: .debug)

        // Should Collect Consent
        self.cachedShouldCollectConsent = nil

        // Consent Status
        if self.cachedConsentStatus != nil {
            self.cachedConsentStatus = nil
            delegate?.onConsentStatusChange(consentStatus)
        }

        // TCF string
        if self.cachedTCFString != nil {
            self.cachedTCFString = nil
            delegate?.onConsentChange(standard: .tcf, value: nil)
        }

        // USP String
        if self.cachedUSPString != nil {
            self.cachedUSPString = nil
            delegate?.onConsentChange(standard: .usp, value: nil)
        }

        // CCPA Opt-In String
        if self.cachedCCPAOptInString != nil {
            self.cachedCCPAOptInString = nil
            delegate?.onConsentChange(standard: .ccpaOptIn, value: nil)
        }
    }
}

/// A delegate proxy that records all the calls made to it and allows to invoke them later using a
/// different delegate.
class ConsentAdapterDelegateDelayProxy: ConsentAdapterDelegate {

    /// The callbacks made to the proxy.
    private var delayedCallbacks: [(ConsentAdapterDelegate?) -> Void] = []

    /// Performs all the recorded callbacks using the specified delegate.
    func relayReceivedCallbacks(to delegate: ConsentAdapterDelegate?) {
        delayedCallbacks.forEach { $0(delegate) }
    }

    func onConsentStatusChange(_ status: ConsentStatus) {
        delayedCallbacks.append({ delegate in
            delegate?.onConsentStatusChange(status)
        })
    }

    func onConsentChange(standard: ConsentStandard, value: ConsentValue?) {
        delayedCallbacks.append({ delegate in
            delegate?.onConsentChange(standard: standard, value: value)
        })
    }
}
