import SwiftUI

// MARK: - 左栏：天空轨迹 / 月相 / 太阳 / 降水

/// 日月轨迹图：上半为白天天空、下半为星空，两条曲线分别是太阳与月亮的地平高度轨迹
struct SkyPathCard: View {
    let astro: AstroInfo
    let place: Place
    var now: Date = Date()

    private var dayStart: Date { WallClock.startOfDay(now) }
    private let horizonRatio: CGFloat = 0.60

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let horizonY = size.height * horizonRatio

            ZStack(alignment: .topLeading) {
                backdrop(size: size, horizonY: horizonY)
                markers(size: size, horizonY: horizonY)
                labels
            }
        }
        .frame(height: 172)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    // MARK: 背景 + 曲线

    private func backdrop(size: CGSize, horizonY: CGFloat) -> some View {
        let calculator = AstroCalculator()

        return Canvas { context, canvasSize in
            let nightRect = CGRect(x: 0, y: horizonY, width: canvasSize.width,
                                   height: canvasSize.height - horizonY)

            context.fill(Path(nightRect), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x131936), Color(hex: 0x0A0E22)]),
                startPoint: CGPoint(x: 0, y: horizonY),
                endPoint: CGPoint(x: 0, y: canvasSize.height)
            ))

            // 星点（固定种子，保证每次绘制一致）
            var seed: UInt64 = 20_261_027
            for _ in 0..<90 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let fx = Double((seed >> 33) % 10_000) / 10_000
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let fy = Double((seed >> 33) % 10_000) / 10_000
                let radius = 0.5 + CGFloat(fy) * 1.2
                let dot = CGRect(x: CGFloat(fx) * canvasSize.width,
                                 y: horizonY + CGFloat(fy) * nightRect.height,
                                 width: radius, height: radius)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.12 + fy * 0.55)))
            }

            let dayRect = CGRect(x: 0, y: 0, width: canvasSize.width, height: horizonY)
            context.fill(Path(dayRect), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x2AA6FF), Color(hex: 0x0A78E0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: horizonY)
            ))

            context.stroke(
                curve(size: canvasSize, horizonY: horizonY) { calculator.sunAltitude($0, lat: place.latitude, lon: place.longitude) },
                with: .color(Color(hex: 0x9ACBFF).opacity(0.9)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )

            context.stroke(
                curve(size: canvasSize, horizonY: horizonY) { calculator.moonAltitudeAt($0, lat: place.latitude, lon: place.longitude) },
                with: .color(.white.opacity(0.30)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
    }

    private func curve(size: CGSize, horizonY: CGFloat, altitudeAt: (Date) -> Double) -> Path {
        var path = Path()
        let steps = 96
        for index in 0...steps {
            let fraction = Double(index) / Double(steps)
            let date = dayStart.addingTimeInterval(fraction * 86_400)
            let point = CGPoint(x: size.width * CGFloat(fraction),
                                y: yFor(altitude: altitudeAt(date), horizonY: horizonY))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func yFor(altitude: Double, horizonY: CGFloat) -> CGFloat {
        // 60° 高度角约等于地平线以上 86% 的可视高度
        horizonY - CGFloat(altitude) * (horizonY * 0.86 / 60)
    }

    // MARK: 当前位置标记

    private func markers(size: CGSize, horizonY: CGFloat) -> some View {
        let fraction = min(1, max(0, now.timeIntervalSince(dayStart) / 86_400))
        let x = min(size.width - 12, max(12, size.width * CGFloat(fraction)))

        return ZStack(alignment: .topLeading) {
            if let moonAltitude = astro.moonAltitude {
                MoonDisc(size: 16)
                    .offset(x: x - 8, y: yFor(altitude: moonAltitude, horizonY: horizonY) - 8)
            }
            if let sunAltitude = astro.sunAltitude {
                SunDisc(size: 18)
                    .offset(x: x - 9, y: yFor(altitude: sunAltitude, horizonY: horizonY) - 9)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: 底部文案

    private var labels: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Text("日出 \(countdown(to: astro.sunrise))")
                Spacer(minLength: 8)
                Text("月落 \(countdown(to: astro.moonset))")
            }
            .font(.system(size: 12.5))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
    }

    private func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        var delta = date.timeIntervalSince(now)
        if delta < 0 { delta += 86_400 }
        let total = Int(delta.rounded())
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}

// MARK: - 月相

struct MoonDetailCard: View {
    let astro: AstroInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(astro.moonPhase.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                inlineRow("年龄", "\(decimal(astro.moonPhase.age, 2)) 天")
                inlineRow("海拔高度", degrees(astro.moonAltitude))
                inlineRow("方位", degrees(astro.moonAzimuth))
                inlineRow("照射范围", "\(decimal(astro.moonPhase.illumination * 100, 2))%")
                inlineRow("距离", "\(grouped(astro.moonPhase.distanceKm)) 公里")
            }

            Spacer(minLength: 0)

            MoonDisc(size: 92)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: 0x18203F), Color(hex: 0x0C1027)],
                               startPoint: .top, endPoint: .bottom)
                StarField(count: 60)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - 太阳

struct SunDetailCard: View {
    let astro: AstroInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("太阳")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentBlue)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    inlineRow("海拔高度", degrees(astro.sunAltitude))
                    inlineRow("方位", degrees(astro.sunAzimuth))
                    inlineRow("距离", "\(grouped(astro.sunDistanceKm)) 公里")
                }
                Spacer(minLength: 0)
                SunDisc(size: 66)
            }
        }
        .card()
    }
}

// MARK: - 降水

struct PrecipitationCard: View {
    let current: CurrentConditions
    let hourly: [HourPoint]

    private var chance: Int {
        hourly.first?.precipitationChance ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("降水")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentBlue)

            valueRow("降雨", "\(chance)%")
            valueRow("降水量", "\(decimal(current.precipitation, current.precipitation < 10 ? 1 : 0)) 毫米")
        }
        .card()
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 图形

/// 月亮圆面：径向渐变 + 环形山，避免引入位图素材
struct MoonDisc: View {
    var size: CGFloat = 90

    private static let craters: [(x: CGFloat, y: CGFloat, r: CGFloat, opacity: Double)] = [
        (-0.20, -0.18, 0.20, 0.10), (0.16, -0.26, 0.13, 0.08), (0.28, 0.10, 0.17, 0.09),
        (-0.06, 0.22, 0.22, 0.07), (-0.30, 0.16, 0.12, 0.09), (0.05, -0.02, 0.30, 0.05),
        (0.34, -0.08, 0.09, 0.10), (-0.14, 0.36, 0.10, 0.08)
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xF4F3EB), Color(hex: 0xC9C7BC), Color(hex: 0x7C7A70)],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: size * 0.04,
                        endRadius: size * 0.72
                    )
                )

            ForEach(Array(Self.craters.enumerated()), id: \.offset) { _, crater in
                Circle()
                    .fill(Color.black.opacity(crater.opacity))
                    .frame(width: size * crater.r, height: size * crater.r)
                    .offset(x: size * crater.x, y: size * crater.y)
                    .blur(radius: size * 0.012)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .white.opacity(0.20), radius: size * 0.10)
    }
}

/// 太阳圆面：径向渐变 + 外发光
struct SunDisc: View {
    var size: CGFloat = 66

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0xFFF6B8), Color(hex: 0xFFD230), Color(hex: 0xFFA81F)],
                    center: UnitPoint(x: 0.42, y: 0.38),
                    startRadius: size * 0.02,
                    endRadius: size * 0.62
                )
            )
            .frame(width: size, height: size)
            .shadow(color: Color(hex: 0xFFC61A).opacity(0.65), radius: size * 0.22)
    }
}

/// 星点背景
struct StarField: View {
    var count: Int = 50

    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 8_675_309
            for _ in 0..<count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let fx = Double((seed >> 33) % 10_000) / 10_000
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let fy = Double((seed >> 33) % 10_000) / 10_000
                let radius = 0.5 + CGFloat(fy) * 1.1
                let dot = CGRect(x: CGFloat(fx) * size.width,
                                 y: CGFloat(fy) * size.height,
                                 width: radius, height: radius)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.10 + fy * 0.5)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 格式化

private func inlineRow(_ label: String, _ value: String) -> some View {
    HStack(spacing: 5) {
        Text(label)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
        Text(value)
            .font(.system(size: 12.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        Spacer(minLength: 0)
    }
}

private func degrees(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(decimal(value, 1))°"
}

private func decimal(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
}

private func grouped(_ value: Double?) -> String {
    guard let value else { return "—" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
}
