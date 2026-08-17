import CoreGraphics

struct FaceFeaturePositions: Equatable {
    var leftEye: CGPoint?
    var rightEye: CGPoint?
    var nose: CGPoint?
    var mouth: CGPoint?

    func point(for feature: MirrorFeature) -> CGPoint? {
        switch feature {
        case .full: nil
        case .leftEye: leftEye
        case .rightEye: rightEye
        case .nose: nose
        case .mouth: mouth
        }
    }

    func smoothed(toward newValue: Self, weight: CGFloat = 0.14) -> Self {
        Self(
            leftEye: Self.blend(leftEye, newValue.leftEye, weight: weight),
            rightEye: Self.blend(rightEye, newValue.rightEye, weight: weight),
            nose: Self.blend(nose, newValue.nose, weight: weight),
            mouth: Self.blend(mouth, newValue.mouth, weight: weight)
        )
    }

    private static func blend(_ old: CGPoint?, _ new: CGPoint?, weight: CGFloat) -> CGPoint? {
        guard let new else { return nil }
        guard let old else { return new }

        let dx = new.x - old.x
        let dy = new.y - old.y
        let distance = hypot(dx, dy)

        // 検出器が生む微小な座標揺れは動きとして反映しない。
        guard distance >= 0.0018 else { return old }

        // ゆっくりした動きは滑らかに、大きな移動には遅れすぎず追従する。
        let adaptiveWeight = min(weight + distance * 1.6, 0.34)

        return CGPoint(
            x: old.x + dx * adaptiveWeight,
            y: old.y + dy * adaptiveWeight
        )
    }
}
