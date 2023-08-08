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
@objc(ChartboostCoreUsercentricsAdapter)
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

    /// The observer to be notified whenever any change happens in the CMP consent status.
    /// This observer is set by Core SDK and is an essential communication channel between Core and the CMP.
    /// Adapters should not set it themselves.
    public weak var observer: ConsentObserver?

    /// The name of the Usercentrics Data Processing Service (DPS) defined in the Usercentrics dashboard for the Chartboost Core SDK.
    let chartboostCoreDPSName: String

    /// The Usercentrics options used to configure the Usercentrics SDK.
    let options: UsercentricsOptions?

    /// The default value for `chartboostCoreDPSName` when none is provided.
    @objc public static var defaultChartboostCoreDPSName = "ChartboostCore"

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
    @objc public convenience init(options: UsercentricsOptions) {
        self.init(options: options, chartboostCoreDPSName: UsercentricsAdapter.defaultChartboostCoreDPSName)
    }

    /// Instantiates a UsercentricsAdapter module which can be passed on a call to ``ChartboostCore.initializeSDK()`
    /// - parameter options: The options to initialize Usercentrics with. Refer to the Usercentrics documentation:
    /// https://docs.usercentrics.com/cmp_in_app_sdk/latest/getting_started/configure/
    /// - parameter chartboostCoreDPSName: The name for the Chartboost Core DPS that matches the one set on the Usercentrics dashboard.
    @objc public init(options: UsercentricsOptions, chartboostCoreDPSName: String = UsercentricsAdapter.defaultChartboostCoreDPSName) {
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
        // Fail if no options provided on init
        guard let options else {
            log("Failed to initialize Usercentrics: no options available.", level: .error)
            completion(InitializationError.usercentricsOptionsNotAvailable)
            return
        }
        // Configure the SDK
        log("Configuring Usercentrics SDK", level: .debug)
        UsercentricsCore.configure(options: options)

        // Start observing consent changes and reporting updates to the observer object
        startObservingConsentChanges()

        // Fetch the initial consent status
        fetchConsentInfo()

        // Report success immediately. If configuration fails it will be retried when calling any Usercentrics method.
        completion(nil)
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

    /// Informs the CMP of the new user consent status.
    /// This method should be used only when a custom consent dialog is presented to the user, thereby making the publisher
    /// responsible for the UI-side of collecting consent. In most cases ``showConsentDialog(_:from:completion:)``should
    /// be used instead.
    /// If the CMP does not support custom consent dialogs or the operation fails for any other reason, the completion
    /// handler is executed with a `false` parameter.
    /// - parameter status: The new consent status.
    /// Pass ``ConsentStatus.unknown`` to reset a previously set consent. E.g. when the user changes.
    /// - parameter source: The source of the new consent status. See the ``ConsentStatusSource`` documentation for more info.
    /// - parameter completion: Handler called to indicate if the operation went through successfully or not.
    public func setConsentStatus(_ status: ConsentStatus, source: ConsentStatusSource, completion: @escaping (Bool) -> Void) {
        log("Setting consent status...", level: .debug)
        UsercentricsCore.isReady(onSuccess: { [weak self] _ in
            guard let self else { return }
            // SDK ready
            switch status {
            case .granted:
                // Accept all consents
                self.log("Accept all consents", level: .debug)
                UsercentricsCore.shared.acceptAll(consentType: self.usercentricsConsentType(from: source))
                // Fetch consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.fetchConsentInfo()

            case .denied:
                // Accept all consents
                self.log("Deny all consents", level: .debug)
                UsercentricsCore.shared.denyAll(consentType: self.usercentricsConsentType(from: source))
                // Fetch consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.fetchConsentInfo()

            case .unknown:
                // Reset all consents
                self.log("Reset", level: .debug)
                UsercentricsCore.reset()

                // Clear cached consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.resetCachedConsentInfo()

                // Usercentrics needs to be configured again after a call to reset()
                self.initialize(completion: { _ in })
            }
            completion(true)
        }, onFailure: { [weak self] error in
            // SDK not ready
            self?.log("SDK not ready: \(error)", level: .error)
            completion(false)
        })
    }

    /// Instructs the CMP to present a consent dialog to the user for the purpose of collecting consent.
    /// - parameter type: The type of consent dialog to present. See the ``ConsentDialogType`` documentation for more info.
    /// If the CMP does not support a given type, it should default to whatever type it does support.
    /// - parameter viewController: The view controller to present the consent dialog from.
    /// - parameter completion: This handler is called to indicate whether the consent dialog was successfully presented or not.
    /// Note that this is called at the moment the dialog is presented, **not when it is dismissed**.
    public func showConsentDialog(_ type: ConsentDialogType, from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        log("Showing consent dialog...", level: .debug)
        UsercentricsCore.isReady(onSuccess: { [weak self] _ in
            // SDK ready
            switch type {
            case .concise:
                self?.banner.showFirstLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("1st layer response: \(userResponse)", level: .trace)
                }
                completion(true)
            case .detailed:
                self?.banner.showSecondLayer(hostView: viewController) { [weak self] userResponse in
                    self?.log("2nd layer response: \(userResponse)", level: .trace)
                }
                completion(true)
            default:
                self?.log("Unknown consent dialog type: \(type)", level: .warning)
                completion(false)
            }
        }, onFailure: { [weak self] error in
            // SDK not ready
            self?.log("SDK not ready: \(error)", level: .error)
            completion(false)
        })
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

            self.log("onConsentUpdated with payload:\n\(payload)", level: .trace)

            // We discard the payload and just pull all the info directly from the SDK.
            // The result should be the same, we do this to simplify our implementation and prevent
            // data from getting out of sync.
            self.fetchConsentInfo()
        }
    }

    /// Pulls all the consent info from the Usercentrics SDK, saves it in the adapter's internal cache,
    /// and reports updates to the adapter observer.
    private func fetchConsentInfo() {
        UsercentricsCore.isReady(onSuccess: { [weak self] status in
            guard let self else { return }

            // Should Collect Consent
            self.cachedShouldCollectConsent = status.shouldCollectConsent

            // Consent Status
            let newConsentStatus: ConsentStatus?
            if let coreDPS = status.consents.first(where: { $0.dataProcessor == self.chartboostCoreDPSName }) {
                newConsentStatus = coreDPS.status ? .granted : .denied
            } else {
                self.log("ChartboostCore DPS not found in payload, expected one named '\(self.chartboostCoreDPSName)'", level: .error)
                newConsentStatus = nil
            }
            if self.cachedConsentStatus != newConsentStatus {
                self.cachedConsentStatus = newConsentStatus
                self.observer?.onConsentStatusChange(self.consentStatus)
            }

            // TCF string
            UsercentricsCore.shared.getTCFData { [weak self] tcfData in
                guard let self else { return }
                let newTCFString = tcfData.tcString.isEmpty ? nil : tcfData.tcString
                if self.cachedTCFString != newTCFString {
                    self.cachedTCFString = newTCFString
                    self.observer?.onConsentChange(standard: .tcf, value: newTCFString.map(ConsentValue.init(stringLiteral:)))
                }
            }

            // USP String
            let uspData = UsercentricsCore.shared.getUSPData()
            let newUSPString = uspData.uspString.isEmpty ? nil : uspData.uspString
            if self.cachedUSPString != newUSPString {
                self.cachedUSPString = newUSPString
                self.observer?.onConsentChange(standard: .usp, value: newUSPString.map(ConsentValue.init(stringLiteral:)))
            }

            // CCPA Opt-In String
            let newCCPAString: ConsentValue?
            if let ccpaOptedOut = uspData.optedOut {
                newCCPAString = ccpaOptedOut.boolValue ? .denied : .granted
            } else {
                newCCPAString = nil
            }
            if self.cachedCCPAOptInString != newCCPAString {
                self.cachedCCPAOptInString = newCCPAString
                self.observer?.onConsentChange(standard: .ccpaOptIn, value: newCCPAString)
            }

        }, onFailure: { [weak self] error in
            guard let self else { return }
            self.log("SDK not ready: \(error)", level: .error)
            self.resetCachedConsentInfo()
        })
    }

    /// Clears the adapter internal cache and reports updates to the observer.
    private func resetCachedConsentInfo() {
        // Should Collect Consent
        self.cachedShouldCollectConsent = nil

        // Consent Status
        if self.cachedConsentStatus != nil {
            self.cachedConsentStatus = nil
            self.observer?.onConsentStatusChange(consentStatus)
        }

        // TCF string
        if self.cachedTCFString != nil {
            self.cachedTCFString = nil
            self.observer?.onConsentChange(standard: .tcf, value: nil)
        }

        // USP String
        if self.cachedUSPString != nil {
            self.cachedUSPString = nil
            self.observer?.onConsentChange(standard: .usp, value: nil)
        }

        // CCPA Opt-In String
        if self.cachedCCPAOptInString != nil {
            self.cachedCCPAOptInString = nil
            self.observer?.onConsentChange(standard: .ccpaOptIn, value: nil)
        }
    }
}
