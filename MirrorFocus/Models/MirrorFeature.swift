import SwiftUI

enum MirrorFeature: String, CaseIterable, Identifiable {
    case full
    case leftEye
    case rightEye
    case nose
    case mouth

    var id: Self { self }

    var title: String {
        switch self {
        case .full: "全体"
        case .leftEye: "左目"
        case .rightEye: "右目"
        case .nose: "鼻"
        case .mouth: "口"
        }
    }

    var symbol: String {
        switch self {
        case .full: "person.crop.rectangle"
        case .leftEye, .rightEye: "eye"
        case .nose: "nose"
        case .mouth: "mouth"
        }
    }

    /// 顔が縦方向の中央付近にあることを前提に、選んだ部位を画面中央へ移動する位置。
    var verticalPoint: CGFloat {
        switch self {
        case .full: 0.50
        case .leftEye, .rightEye: 0.39
        case .nose: 0.50
        case .mouth: 0.62
        }
    }

    var magnification: CGFloat {
        switch self {
        case .full: 1.00
        case .leftEye, .rightEye: 2.65
        case .nose: 2.35
        case .mouth: 2.35
        }
    }
}

enum LightMode: Int, CaseIterable, Identifiable {
    case off
    case white

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "ライト オフ"
        case .white: "白色ライト"
        }
    }

    var symbol: String {
        self == .off ? "sun.max" : "sun.max.fill"
    }

    var color: Color {
        .white
    }

    var next: Self {
        switch self {
        case .off: .white
        case .white: .off
        }
    }
}

struct RecordedClip: Identifiable {
    let id = UUID()
    let url: URL
}
