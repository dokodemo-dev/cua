// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)

import CuaBotsServiceKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The koala's colours, without the SVG.
public enum AvatarPalette {
    public static func face(_ color: String) -> Color {
        switch color {
        case "violet": Color(hex: 0x8B5CF6)
        case "orange": Color(hex: 0xFF7A2F)
        case "cloud": Color(hex: 0xE3E7EC)
        case "graphite": Color(hex: 0x262A31)
        case "slate": Color(hex: 0x8E98A3)
        default: Color(hex: 0x61BCFF)
        }
    }

    public static func ink(_ color: String) -> Color {
        switch color {
        case "cloud", "orange", "sky", "violet": Color(hex: 0x0B0E13)
        default: .white
        }
    }

    public static let names: [(key: String, label: String)] = [
        ("violet", "すみれ"), ("orange", "オレンジ"), ("sky", "そら"),
        ("cloud", "くも"), ("slate", "スレート"), ("graphite", "こく"),
    ]
}

/// A phone-sized badge with the Bot's initial: it reads better than a 34pt
/// face and keeps this target dependency-free.
public struct BotAvatar: View {
    public let avatar: Avatar?
    public let name: String
    public var size: CGFloat = 36

    public init(avatar: Avatar?, name: String, size: CGFloat = 36) {
        self.avatar = avatar
        self.name = name
        self.size = size
    }

    public var body: some View {
        let color = avatar?.color ?? "sky"
        Circle()
            .fill(AvatarPalette.face(color))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(AvatarPalette.ink(color))
            }
            .accessibilityHidden(true)
    }
}
#endif
