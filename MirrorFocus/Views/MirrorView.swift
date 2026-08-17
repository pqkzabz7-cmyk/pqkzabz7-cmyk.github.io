import SwiftUI
import UIKit

struct MirrorView: View {
    private static let topSystemGestureExclusionHeight: CGFloat = 72
    private static let pressMovementTolerance: CGFloat = 18

    @StateObject private var camera = CameraManager()
    @EnvironmentObject private var adConsent: AdConsentManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var selectedFeature: MirrorFeature = .full
    @State private var isMirrored = true
    @State private var lightMode: LightMode = .off
    @State private var zoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1
    @State private var isPressActive = false
    @State private var didStartRecordingForPress = false
    @State private var recordingDelayTask: Task<Void, Never>?
    @State private var originalBrightness: CGFloat?

    private var effectiveZoom: CGFloat {
        min(max(zoom * gestureZoom, 1), 4)
    }

    private var displayScale: CGFloat {
        selectedFeature.magnification * effectiveZoom
    }

    var body: some View {
        GeometryReader { proxy in
            let bannerHeight = BannerAdView.bannerHeight
            let controlAdSpacing: CGFloat = 8
            let mirrorSize = CGSize(
                width: proxy.size.width,
                height: max(proxy.size.height - bannerHeight - controlAdSpacing, 1)
            )

            VStack(spacing: 0) {
                ZStack {
                    Color.black

                    mirrorSurface(size: mirrorSize)

                    controls
                        .zIndex(2)

                    statusOverlay

                    ScreenLightOverlay(mode: lightMode)
                }
                .frame(width: mirrorSize.width, height: mirrorSize.height)
                .clipped()

                Color.black
                    .frame(height: controlAdSpacing)

                BannerAdView()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: .top)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            camera.startSession()
        }
        .onDisappear {
            cancelPendingPress(discardRecording: true)
            camera.stopSession()
            restoreBrightness()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.startSession()
                applyBrightness(for: lightMode)
            case .inactive, .background:
                cancelPendingPress(discardRecording: true)
                restoreBrightness()
            @unknown default:
                break
            }
        }
        .sheet(item: $camera.recordedClip, onDismiss: {
            camera.discardRecordedClip()
        }) { clip in
            RecordingPreviewView(clip: clip)
        }
    }

    private func mirrorSurface(size: CGSize) -> some View {
        let focusOffset = focusOffset(in: size)

        return ZStack {
            CameraPreview(session: camera.session)

            if let frozenFrame = camera.frozenFrame {
                Image(decorative: frozenFrame, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
        .scaleEffect(displayScale)
        .offset(x: focusOffset.width, y: focusOffset.height)
        .animation(nil, value: isMirrored)
        .animation(.snappy(duration: 0.30), value: selectedFeature)
        .animation(.linear(duration: 0.11), value: camera.faceFeaturePositions)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(zoomGesture)
        .simultaneousGesture(pressGesture)
        .accessibilityLabel(camera.frozenFrame == nil ? "鏡のライブ映像" : "静止した鏡の映像")
        .accessibilityHint("タップで静止または再開。長押しで録画します。")
    }

    private func focusOffset(in viewSize: CGSize) -> CGSize {
        guard selectedFeature != .full else { return .zero }

        let positions = camera.frozenFaceFeaturePositions ?? camera.faceFeaturePositions
        let frameSize = camera.frozenCameraFrameSize ?? camera.cameraFrameSize

        guard let normalizedPoint = positions.point(for: selectedFeature),
              frameSize.width > 0,
              frameSize.height > 0 else {
            return CGSize(
                width: 0,
                height: (0.5 - selectedFeature.verticalPoint) * viewSize.height * displayScale
            )
        }

        let point = previewPoint(
            normalizedPoint,
            frameSize: frameSize,
            viewSize: viewSize,
            mirrored: isMirrored
        )

        return CGSize(
            width: (viewSize.width / 2 - point.x) * displayScale,
            height: (viewSize.height / 2 - point.y) * displayScale
        )
    }

    private func previewPoint(
        _ normalizedPoint: CGPoint,
        frameSize: CGSize,
        viewSize: CGSize,
        mirrored: Bool
    ) -> CGPoint {
        let normalizedX = mirrored ? 1 - normalizedPoint.x : normalizedPoint.x
        let aspectFillScale = max(
            viewSize.width / frameSize.width,
            viewSize.height / frameSize.height
        )
        let displayedSize = CGSize(
            width: frameSize.width * aspectFillScale,
            height: frameSize.height * aspectFillScale
        )
        let crop = CGSize(
            width: (displayedSize.width - viewSize.width) / 2,
            height: (displayedSize.height - viewSize.height) / 2
        )

        return CGPoint(
            x: normalizedX * displayedSize.width - crop.width,
            y: normalizedPoint.y * displayedSize.height - crop.height
        )
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureZoom) { value, state, _ in
                state = value
            }
            .onChanged { _ in
                cancelPressForZoomIfNeeded()
            }
            .onEnded { value in
                zoom = min(max(zoom * value, 1), 4)
            }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard value.startLocation.y >= Self.topSystemGestureExclusionHeight else {
                    cancelPendingPress(discardRecording: true)
                    return
                }

                guard didStartRecordingForPress
                        || hypot(value.translation.width, value.translation.height)
                            <= Self.pressMovementTolerance else {
                    cancelPendingPress(discardRecording: true)
                    return
                }

                guard !isPressActive,
                      camera.status == .ready,
                      !camera.isRecording else { return }

                isPressActive = true
                scheduleRecordingStart()
            }
            .onEnded { value in
                guard value.startLocation.y >= Self.topSystemGestureExclusionHeight,
                      didStartRecordingForPress
                        || hypot(value.translation.width, value.translation.height)
                            <= Self.pressMovementTolerance else {
                    cancelPendingPress(discardRecording: true)
                    return
                }

                guard isPressActive else { return }
                isPressActive = false
                recordingDelayTask?.cancel()
                recordingDelayTask = nil

                if didStartRecordingForPress {
                    didStartRecordingForPress = false
                    camera.stopRecording()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.toggleFreeze()
                }
            }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    operationHint

                    if camera.isRecording {
                        recordingBadge
                    } else if camera.frozenFrame != nil {
                        Text("PAUSED")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    if adConsent.shouldShowPrivacyOptions {
                        Button {
                            adConsent.presentPrivacyOptions()
                        } label: {
                            Label("プライバシー設定", systemImage: "hand.raised")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    if effectiveZoom > 1.01 {
                        Button {
                            withAnimation(.snappy) { zoom = 1 }
                        } label: {
                            Text(String(format: "%.1f×", effectiveZoom))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(height: 48)
                                .padding(.horizontal, 14)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("拡大率をリセット")
                    }

                    RoundControlButton(
                        symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        title: isMirrored ? "左右反転を解除" : "左右反転",
                        isActive: isMirrored
                    ) {
                        isMirrored.toggle()
                    }

                    RoundControlButton(
                        symbol: lightMode.symbol,
                        title: lightMode.title,
                        tint: lightMode.color,
                        isActive: lightMode != .off
                    ) {
                        cycleLight()
                    }
                }
            }
            .padding(.horizontal, 16)
            .safeAreaPadding(.top, 12)

            Spacer()

            FeaturePicker(selection: $selectedFeature)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var operationHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("タップで静止", systemImage: "hand.tap")
            Label("長押しで録画", systemImage: "record.circle")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var recordingBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = context.date.timeIntervalSince(camera.recordingStartedAt ?? context.date)
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)

                Text(Self.durationText(duration))
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.red.opacity(0.24), in: Capsule())
            .overlay {
                Capsule().stroke(Color.red.opacity(0.72), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .requestingPermission, .configuring:
            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                Text("カメラを準備しています…")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        case .denied:
            unavailableCard(
                symbol: "camera.fill",
                title: "カメラへのアクセスが必要です",
                message: "設定でカメラを許可すると、鏡を利用できます。",
                showsSettingsButton: true
            )
        case let .unavailable(message):
            unavailableCard(
                symbol: "iphone.slash",
                title: "カメラを利用できません",
                message: message,
                showsSettingsButton: false
            )
        case .ready:
            EmptyView()
        }
    }

    private func unavailableCard(
        symbol: String,
        title: String,
        message: String,
        showsSettingsButton: Bool
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .semibold))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if showsSettingsButton {
                Button("設定を開く") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(24)
    }

    private func cancelPressForZoomIfNeeded() {
        guard isPressActive else { return }
        cancelPendingPress(discardRecording: true)
    }

    private func scheduleRecordingStart() {
        recordingDelayTask?.cancel()
        recordingDelayTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }

            guard isPressActive else { return }
            didStartRecordingForPress = true
            camera.startRecording(mirrored: isMirrored)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func cancelPendingPress(discardRecording: Bool = false) {
        let shouldCancelRecording = discardRecording
            && (didStartRecordingForPress || camera.isRecording)

        isPressActive = false
        recordingDelayTask?.cancel()
        recordingDelayTask = nil
        didStartRecordingForPress = false

        if shouldCancelRecording {
            camera.cancelRecording()
        }
    }

    private func cycleLight() {
        let nextMode = lightMode.next
        withAnimation(.easeInOut(duration: 0.24)) {
            lightMode = nextMode
        }
        applyBrightness(for: nextMode)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func applyBrightness(for mode: LightMode) {
        if mode == .off {
            restoreBrightness()
            return
        }

        if originalBrightness == nil {
            originalBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 1
    }

    private func restoreBrightness() {
        guard let originalBrightness else { return }
        UIScreen.main.brightness = originalBrightness
        self.originalBrightness = nil
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

#Preview {
    MirrorView()
}
