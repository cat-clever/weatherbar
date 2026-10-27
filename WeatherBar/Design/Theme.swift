import SwiftUI
import AppKit
import Foundation

// MARK: - 色板

enum Theme {
    static let bgTop = Color(hex: 0x2E2C63)
    static let bgBottom = Color(hex: 0x1D1C40)
    static let bgBase = Color(hex: 0x14132C)

    static let card = Color.white.opacity(0.07)
    static let cardRaised = Color.white.opacity(0.11)
    static let cardStroke = Color.white.opacity(0.10)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xB6B4DA)
    static let textTertiary = Color(hex: 0x8B89B4)

    static let accentBlue = Color(hex: 0x4C8DF6)
    static let accentPrecip = Color(hex: 0x5BA8F7)
    static let accentSun = Color(hex: 0xFFD34D)
    static let accentMoon = Color(hex: 0xD9D8EC)

    static let chartLine = Color.white.opacity(0.85)
    static let chartFillTop = Color(hex: 0x2FBDF0).opacity(0.55)
    static let chartFillBottom = Color(hex: 0x2FBDF0).opacity(0.0)

    static let onboardingBackground = Color(hex: 0x26254F)

    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 640
    /// 悬停时出现在面板左侧的独立浮窗
    static let leftPanelWidth: CGFloat = 320
    static let leftPanelGap: CGFloat = 8
    static let pagePadding: CGFloat = 10
    static let blockGap: CGFloat = 10
    static let cardRadius: CGFloat = 12
    /// 实况区悬停高亮：圆角与外扩距离（外扩要小于 pagePadding，避免被滚动区域裁掉）
    static let headerHighlightRadius: CGFloat = 8
    static let headerHighlightInset: CGFloat = 5
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - 卡片容器

struct CardBackground: ViewModifier {
    var raised: Bool = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(raised ? Theme.cardRaised : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(raised: Bool = false) -> some View {
        modifier(CardBackground(raised: raised))
    }

    /// 鼠标悬停时描一圈系统强调色，和原版一致
    func hoverHighlight(radius: CGFloat = Theme.cardRadius,
                        inset: CGFloat = 0,
                        lineWidth: CGFloat = 1.5) -> some View {
        modifier(HoverHighlightModifier(radius: radius, inset: inset, lineWidth: lineWidth))
    }
}

struct HoverHighlightModifier: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var inset: CGFloat = 0
    var lineWidth: CGFloat = 1.5

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: lineWidth)
                    .padding(-inset)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - 格式化

enum Formatters {
    static func temperature(_ celsius: Double, unit: TemperatureUnit, decimals: Int = 0) -> String {
        let v = unit.convert(fromCelsius: celsius)
        return String(format: "%.\(decimals)f°", v)
    }

    static func temperatureShort(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(fromCelsius: celsius).rounded()))°"
    }

    static func wind(_ kmh: Double, unit: WindUnit) -> String {
        let v = unit.convert(fromKmh: kmh)
        let decimals = v < 10 ? 1 : 0
        return String(format: "%.\(decimals)f \(unit.label)", v)
    }

    static func windShort(_ kmh: Double, unit: WindUnit) -> String {
        "\(Int(unit.convert(fromKmh: kmh).rounded()))"
    }

    static func pressure(_ hPa: Double, unit: PressureUnit) -> String {
        let v = unit.convert(fromHPa: hPa)
        switch unit {
        case .hpa:
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 1
            f.minimumFractionDigits = 1
            return (f.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v)) + " \(unit.label)"
        default:
            return String(format: "%.2f %@", v, unit.label)
        }
    }

    static func visibility(_ meters: Double) -> String {
        let km = meters / 1000
        if km >= 10 { return "\(Int(km.rounded())) 公里" }
        return String(format: "%.1f 公里", km)
    }

    static func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = WallClock.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func clockLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return hourLabel(date)
    }

    static func weekday(_ date: Date, index: Int) -> String {
        if index == 0 { return "今天" }
        if index == 1 { return "明天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = WallClock.timeZone
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    static func relativeTime(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h) 小时 \(m) 分钟"
    }

    static func signedMinutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 0 ? "+\(m) 分钟" : "\(m) 分钟"
    }

    static func windDirectionArrow(_ degrees: Double) -> String {
        // 风向为"来向"，箭头指向去向
        let normalized = (degrees + 180).truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % 8
        return ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"][index]
    }
}
