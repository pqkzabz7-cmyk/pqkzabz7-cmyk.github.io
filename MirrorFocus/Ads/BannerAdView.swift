import GoogleMobileAds
import SwiftUI
import UIKit

struct BannerAdView: View {
    static let bannerHeight: CGFloat = 50
    @EnvironmentObject private var adConsent: AdConsentManager

    private var adSize: AdSize {
        AdSizeBanner
    }

    private var bannerSize: CGSize {
        cgSize(for: adSize)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            if adConsent.canRequestAds {
                BannerAdRepresentable(adSize: adSize)
                    .frame(width: bannerSize.width, height: bannerSize.height)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.bannerHeight)
        .background(Color.black)
    }
}

private struct BannerAdRepresentable: UIViewRepresentable {
    let adSize: AdSize

    func makeUIView(context: Context) -> BannerContainerView {
        let container = BannerContainerView(adSize: adSize)
        container.banner.adUnitID = AdConfiguration.bannerUnitID
        container.banner.rootViewController = Self.rootViewController
        container.banner.load(Request())
        return container
    }

    func updateUIView(_ container: BannerContainerView, context: Context) {
        let banner = container.banner
        banner.rootViewController = Self.rootViewController

        guard !isAdSizeEqualToSize(size1: banner.adSize, size2: adSize) else { return }
        banner.adSize = adSize
        container.updateScale()
        banner.load(Request())
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}

private final class BannerContainerView: UIView {
    let banner: BannerView
    private let displaySize: CGSize

    init(adSize: AdSize) {
        banner = BannerView(adSize: adSize)
        displaySize = cgSize(for: adSize)
        super.init(frame: CGRect(origin: .zero, size: displaySize))

        backgroundColor = .clear
        clipsToBounds = true
        addSubview(banner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        displaySize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScale()
    }

    func updateScale() {
        let sourceSize = banner.adSize.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }

        banner.transform = .identity
        banner.bounds = CGRect(origin: .zero, size: sourceSize)
        banner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        banner.transform = CGAffineTransform(
            scaleX: displaySize.width / sourceSize.width,
            y: displaySize.height / sourceSize.height
        )
    }
}
