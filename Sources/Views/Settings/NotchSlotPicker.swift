import SwiftUI

/// "Show on the notch": one chip per provider, at most two lit. The count
/// badge reads n/2; a third tap is refused with a short hint instead of
/// silently evicting something.
struct NotchSlotPicker: View {
    @ObservedObject private var slots = NotchSlotStore.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @State private var refused = false

    var body: some View {
        let current = slots.slots
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.tr("Show on the notch"))
                    .font(Typography.rowTitle)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(refused ? L10n.tr("Pick at most two") : "\(current.count) / \(NotchSlotStore.maxSlots)")
                    .font(Typography.chip)
                    .foregroundStyle(refused ? IslandColor.alertAmber : IslandColor.liveTeal)
                    .animation(.easeOut(duration: 0.2), value: refused)
            }
            HStack(spacing: 6) {
                ForEach(IslandProvider.allCases.filter(\.isAvailable)) { provider in
                    chip(provider, selected: current.contains(provider),
                         position: current.firstIndex(of: provider))
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func chip(_ provider: IslandProvider, selected: Bool, position: Int?) -> some View {
        Button {
            withAnimation(.openMorph) {
                if !slots.toggle(provider) {
                    refused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { refused = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let logo = provider.logo {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                }
                Text(provider.displayName)
                    .font(Typography.button)
                if let position {
                    Text(position == 0 ? L10n.tr("Left") : L10n.tr("Right"))
                        .font(Typography.chip)
                        .opacity(0.6)
                }
            }
            .foregroundStyle(selected ? provider.color : .white.opacity(0.45))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(selected ? provider.color.opacity(0.16) : .white.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(selected ? provider.color.opacity(0.5) : .white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
