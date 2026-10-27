import SwiftUI
import AppKit

// MARK: - 地区切换列表

struct RegionSwitcherView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var router: PopoverRouter

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(places.places.enumerated()), id: \.element.id) { item in
                        row(place: item.element)
                        if item.offset == 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Rectangle()
                .fill(Theme.cardStroke)
                .frame(height: 1)

            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { router.route = .regionSearch }
                } label: {
                    Text("＋ 添加地区…")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    router.openSettings()
                } label: {
                    Text("⚙ 管理")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accentBlue)
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .background(Theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private func row(place: Place) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(place.id == places.activeID ? Theme.accentBlue : Color.clear)
                .frame(width: 2, height: 18)
                .clipShape(Capsule())

            Image(systemName: place.isCurrentLocation ? "location.fill" : "mappin")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(place.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if place.id == places.activeID {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentBlue)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .background(Color.clear)
        .onTapGesture {
            select(place)
        }
        .contextMenu {
            Button("设为当前") { select(place) }
            if !place.isCurrentLocation {
                Button("删除", role: .destructive) {
                    places.remove(place.id)
                    Task { await store.refresh(force: true) }
                }
            }
        }
    }

    private func select(_ place: Place) {
        guard place.id != places.activeID else {
            withAnimation(.easeOut(duration: 0.18)) { router.route = .main }
            return
        }
        places.setActive(place.id)
        withAnimation(.easeOut(duration: 0.18)) { router.route = .main }
        Task { await store.refresh(force: true) }
    }
}

// MARK: - 地区搜索

struct RegionSearchView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var router: PopoverRouter

    @State private var query = ""
    @State private var results: [Place] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { router.route = .main }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Text("添加地区")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if isSearching {
                    ProgressView().controlSize(.mini)
                }
            }

            TextField("输入城市名，如 上海 / Tokyo / New York", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: query) { newValue in scheduleSearch(newValue) }

            Button {
                Task { await useCurrentLocation() }
            } label: {
                Label("使用当前位置", systemImage: "location.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentBlue)
            }
            .buttonStyle(.plain)

            if let message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { place in
                        Button {
                            add(place)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(place.subtitle.isEmpty ? String(format: "%.2f, %.2f", place.latitude, place.longitude) : place.subtitle)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accentBlue)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)

            if results.isEmpty && !query.isEmpty && !isSearching {
                Text("没有找到匹配的地区")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        message = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await GeocodingService.shared.search(trimmed)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = found
                isSearching = false
            }
        }
    }

    private func add(_ place: Place) {
        switch places.add(place) {
        case .success:
            message = "已添加 \(place.displayName)"
        case .failure(.duplicate):
            message = "该地区已存在，已切换"
        case .failure(.limitReached(let max)):
            message = "最多 \(max) 个地区"
        case .failure:
            message = "添加失败"
        }
        Task { await store.refresh(force: true) }
        withAnimation(.easeOut(duration: 0.18)) { router.route = .main }
    }

    private func useCurrentLocation() async {
        do {
            let place = try await store.locator.requestPlace()
            places.updateCurrentLocation(place)
            if let current = places.places.first(where: { $0.isCurrentLocation }) {
                places.setActive(current.id)
            }
            await store.refresh(force: true)
            withAnimation(.easeOut(duration: 0.18)) { router.route = .main }
        } catch {
            message = error.localizedDescription
        }
    }
}
