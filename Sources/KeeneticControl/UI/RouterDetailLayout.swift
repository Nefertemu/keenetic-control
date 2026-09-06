import SwiftUI

/// Баннеры участвуют в раскладке и не перекрывают содержимое раздела.
struct RouterDetailLayout<Banners: View, Content: View>: View {
    @ViewBuilder var banners: () -> Banners
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            banners().fixedSize(horizontal: false, vertical: true)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .background(Palette.canvas)
    }
}

struct RouterUpdateBanners: View {
    var release: AvailableUpdate?
    var finding: AutoUpdater.Finding?
    var activeRouterID: UUID
    var onDismissRelease: () -> Void
    var onDismissFinding: () -> Void
    var onViewPlan: (Plan) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let release { releaseBanner(release) }
            if let finding { updateBanner(finding) }
        }
    }

    /// Вышла новая версия приложения. Ничего не скачиваем сами — только
    /// говорим и открываем страницу релиза.
    private func releaseBanner(_ release: AvailableUpdate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Вышла версия \(release.version)")
                    .font(.system(size: 12, weight: .semibold))
                Text("У тебя \(Bundle.appVersion). Приложение ничего не скачивает само.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Открыть релиз") { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
            Button {
                onDismissRelease()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Скрыть до следующей версии")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Фоновая сверка что-то нашла: готовый план можно посмотреть из баннера.
    private func updateBanner(_ found: AutoUpdater.Finding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Источники разошлись с «\(found.routerName)»")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .help(found.routerName)
                Text(found.plan.summary.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if found.routerID == activeRouterID {
                Button("Посмотреть план") { onViewPlan(found.plan) }
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.warning))
                    .fixedSize()
            } else {
                Text("проверялся другой роутер")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Button {
                onDismissFinding()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Скрыть до следующей проверки")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Palette.warning.opacity(0.5), lineWidth: 1)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

}
