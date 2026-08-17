import SwiftUI

struct RoundControlButton: View {
    let symbol: String
    let title: String
    var tint: Color = .white
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : tint)
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(isActive ? tint : Color.black.opacity(0.42))
                        .background(.ultraThinMaterial, in: Circle())
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(isActive ? 0.72 : 0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct FeaturePicker: View {
    @Binding var selection: MirrorFeature

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MirrorFeature.allCases) { feature in
                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        selection = feature
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 20)

                        Text(feature.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(selection == feature ? Color.black : Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(selection == feature ? Color.white : Color.clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == feature ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
}

struct ScreenLightOverlay: View {
    let mode: LightMode

    var body: some View {
        if mode != .off {
            ZStack {
                Rectangle()
                    .fill(mode.color.opacity(0.08))

                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(mode.color.opacity(0.97), lineWidth: 14)
                    .blur(radius: 5)
                    .padding(4)

                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(mode.color.opacity(0.82), lineWidth: 5)
                    .padding(7)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
