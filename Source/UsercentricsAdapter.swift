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

    public enum InitializationError: String, Error {
        case usercentricsOptionsNotAvailable
    }

    public let moduleID = "usercentrics"

    public let moduleVersion = "0.2.8.0.0"

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
    /// - parameter chartboostCoreDPSName: The name for the Chartboost Core DPS that matches the one set on the Usercentrics dashboard.
    public init(options: UsercentricsOptions, chartboostCoreDPSName: String = UsercentricsAdapter.defaultChartboostCoreDPSName) {
        self.options = options
        self.chartboostCoreDPSName = chartboostCoreDPSName
    }

    public init(credentials: [String : Any]?) {
        self.options = Self.usercentricsOptions(from: credentials?["options"] as? [String: Any])
        self.chartboostCoreDPSName = credentials?["coreDpsName"] as? String ?? Self.defaultChartboostCoreDPSName
    }

    public func initialize(completion: @escaping (Error?) -> Void) {
        // Fail if no options provided on init
        guard let options else {
            print("[Usercentrics Adapter] Failed to initialize Usercentrics: no options available.")
            completion(InitializationError.usercentricsOptionsNotAvailable)
            return
        }
        // Configure the SDK
        print("[Usercentrics Adapter] Configuring SDK")
        UsercentricsCore.configure(options: options)

        // Start observing consent changes and reporting updates to the observer object
        startObservingConsentChanges()

        // Fetch the initial consent status
        fetchConsentInfo()

        // Report success immediately. If configuration fails it will be retried when calling any Usercentrics method.
        completion(nil)
    }

    public var shouldCollectConsent: Bool {
        cachedShouldCollectConsent ?? true
    }

    public var consentStatus: ConsentStatus {
        cachedConsentStatus ?? .unknown
    }

    public var consents: [ConsentStandard : ConsentValue] {
        var consents: [ConsentStandard: ConsentValue] = [:]
        consents[.tcf] = cachedTCFString.map(ConsentValue.init(stringLiteral:))
        consents[.usp] = cachedUSPString.map(ConsentValue.init(stringLiteral:))
        consents[.ccpaOptIn] = cachedCCPAOptInString
        return consents
    }

    public func setConsentStatus(_ status: ConsentStatus, source: ConsentStatusSource, completion: @escaping (Bool) -> Void) {
        print("[Usercentrics Adapter] Setting consent status...")
        UsercentricsCore.isReady(onSuccess: { [weak self] _ in
            guard let self else { return }
            // SDK ready
            switch status {
            case .granted:
                // Accept all consents
                print("[Usercentrics Adapter] Accept all consents")
                UsercentricsCore.shared.acceptAll(consentType: self.usercentricsConsentType(from: source))
                // Fetch consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.fetchConsentInfo()

            case .denied:
                // Accept all consents
                print("[Usercentrics Adapter] Deny all consents")
                UsercentricsCore.shared.denyAll(consentType: self.usercentricsConsentType(from: source))
                // Fetch consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.fetchConsentInfo()

            case .unknown:
                // Reset all consents
                print("[Usercentrics Adapter] Reset")
                UsercentricsCore.reset()

                // Clear cached consent info. Usercentrics does not report updates triggered by programmatic changes.
                self.resetCachedConsentInfo()

                // Usercentrics needs to be configured again after a call to reset()
                self.initialize(completion: { _ in })
            }
            completion(true)
        }, onFailure: { error in
            // SDK not ready
            print("[Usercentrics Adapter] SDK not ready: \(error)")
            completion(false)
        })
    }

    public func showConsentDialog(_ type: ConsentDialogType, from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        print("[Usercentrics Adapter] Showing consent dialog...")
        UsercentricsCore.isReady(onSuccess: { [weak self] _ in
            // SDK ready
            switch type {
            case .concise:
                self?.banner.showFirstLayer(hostView: viewController) { userResponse in
                    print("[Usercentrics Adapter] 1st layer response: \(userResponse)")
                }
                completion(true)
            case .detailed:
                self?.banner.showSecondLayer(hostView: viewController) { userResponse in
                    print("[Usercentrics Adapter] 2nd layer response: \(userResponse)")
                }
                completion(true)
            default:
                print("[Usercentrics Adapter] Unknown consent dialog type: \(type)")
                completion(false)
            }
        }, onFailure: { error in
            // SDK not ready
            print("[Usercentrics Adapter] SDK not ready: \(error)")
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
        print("[Usercentrics Adapter] Starting to observe consent changes")

        UsercentricsEvent.shared.onConsentUpdated { [weak self] payload in
            print("[Usercentrics Adapter] onConsentUpdated with payload:\n\(payload)")
            guard let self else { return }

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
                print("[Usercentrics Adapter] ChartboostCore DPS not found in payload, expected one named '\(self.chartboostCoreDPSName)'")
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
            print("[Usercentrics Adapter] SDK not ready: \(error)")
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
