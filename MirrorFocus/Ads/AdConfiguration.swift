import Combine
import Foundation
import GoogleMobileAds
import UserMessagingPlatform

enum AdConfiguration {
    // Google公式のiOSバナー広告用テストID。本番公開前に実際の広告ユニットIDへ変更する。
    static let bannerUnitID = "ca-app-pub-3940256099942544/2435281174"
}

@MainActor
final class AdConsentManager: ObservableObject {
    @Published private(set) var canRequestAds = false
    @Published private(set) var shouldShowPrivacyOptions = false

    private var hasRequestedConsent = false
    private var didStartMobileAds = false

    func requestConsentIfNeeded() {
        guard !hasRequestedConsent else { return }
        hasRequestedConsent = true

        let parameters = RequestParameters()
        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.refreshAdAvailability()
                guard error == nil else { return }

                ConsentForm.loadAndPresentIfRequired(from: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshAdAvailability()
                    }
                }
            }
        }

        // 前回起動時の同意が有効なら、情報更新の完了を待たずに広告を開始できる。
        refreshAdAvailability()
    }

    func presentPrivacyOptions() {
        ConsentForm.presentPrivacyOptionsForm(from: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAdAvailability()
            }
        }
    }

    private func refreshAdAvailability() {
        let consentInformation = ConsentInformation.shared
        shouldShowPrivacyOptions = consentInformation.privacyOptionsRequirementStatus == .required
        canRequestAds = consentInformation.canRequestAds

        guard canRequestAds, !didStartMobileAds else { return }
        didStartMobileAds = true
        MobileAds.shared.start()
    }
}
