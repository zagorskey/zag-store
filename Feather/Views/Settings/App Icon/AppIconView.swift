//
//  AppIconView.swift
//  Feather
//
//  Zag Store appearance-aware icon gallery.
//

import SwiftUI
import NimbleViews
import UIKit

struct AppIconView: View {
    @Binding var currentIcon: String?
    @State private var previewAppearance = "Light"
    @State private var gradientRotation = false
    @State private var selectedPulse: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct IconOption: Identifiable {
        let id: String
        let title: String
        let alternateName: String?
        let lightPreview: String
        let darkPreview: String
    }

    private let options: [IconOption] = [
        .init(
            id: "official",
            title: "Official",
            alternateName: nil,
            lightPreview: "ZagOriginalLight",
            darkPreview: "ZagOriginalDark"
        ),
        .init(
            id: "clear-glass",
            title: "Liquid Glass",
            alternateName: "ZagClearGlass",
            lightPreview: "ZagClearGlassLight",
            darkPreview: "ZagClearGlassDark"
        ),
        .init(
            id: "firewood",
            title: "Burning Wood",
            alternateName: "ZagFirewood",
            lightPreview: "ZagFirewoodLight",
            darkPreview: "ZagFirewoodDark"
        ),
        .init(
            id: "matrix",
            title: "Matrix",
            alternateName: "ZagMatrix",
            lightPreview: "ZagMatrixLight",
            darkPreview: "ZagMatrixDark"
        ),
        .init(
            id: "money",
            title: "Golden Reserve",
            alternateName: "ZagMoney",
            lightPreview: "ZagMoneyLight",
            darkPreview: "ZagMoneyDark"
        ),
        .init(
            id: "gbp",
            title: "Sterling",
            alternateName: "ZagGBP",
            lightPreview: "ZagGBPLight",
            darkPreview: "ZagGBPDark"
        ),
        .init(
            id: "neon-flux",
            title: "Neon Flux",
            alternateName: "ZagNeonFlux",
            lightPreview: "ZagNeonFluxLight",
            darkPreview: "ZagNeonFluxDark"
        )
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private func image(named name: String) -> UIImage? {
        if let image = UIImage(named: name) { return image }
        let url = Bundle.main.bundleURL.appendingPathComponent(name + ".png")
        return UIImage(contentsOfFile: url.path)
    }

    private func select(_ option: IconOption) {
        guard currentIcon != option.alternateName else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                currentIcon = UIApplication.shared.alternateIconName
                if !reduceMotion {
                    selectedPulse = option.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        if selectedPulse == option.id { selectedPulse = nil }
                    }
                }
            }
        }
    }

    private func iconCard(_ option: IconOption) -> some View {
        let selected = currentIcon == option.alternateName
        let available = option.alternateName == nil || image(named: option.lightPreview) != nil

        return Button {
            select(option)
        } label: {
            VStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if let icon = image(named: option.lightPreview) {
                            Image(uiImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .opacity(previewAppearance == "Light" ? 1 : 0)
                        }
                        if let icon = image(named: option.darkPreview) {
                            Image(uiImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .opacity(previewAppearance == "Dark" ? 1 : 0)
                        }
                        if image(named: option.lightPreview) == nil && image(named: option.darkPreview) == nil {
                            Image(systemName: "app.fill")
                                .resizable()
                                .scaledToFit()
                                .padding(24)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: previewAppearance)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 25, height: 25)
                            .background(Circle().fill(AngularGradient(colors: ZagSelfUpdateSpectrum.colors, center: .center)))
                            .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 3))
                            .offset(x: 6, y: 5)
                    }
                }

                Text(option.title)
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.055),
                        lineWidth: 0.6
                    )
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 23, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                colors: ZagSelfUpdateSpectrum.colors,
                                center: .center,
                                angle: .degrees(gradientRotation ? 360 : 0)
                            ),
                            lineWidth: 2
                        )
                }
            }
            .shadow(color: selected ? ZagSelfUpdateSpectrum.colors[0].opacity(0.13) : .clear, radius: 8)
            .scaleEffect(selectedPulse == option.id ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: selectedPulse)
            .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .accessibilityLabel(option.title + (selected ? ", selected" : ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    var body: some View {
        Form {
            Section {
                // Measure the real scope instead of shifting a 76-point
                // search bar outside a 21-point Form row.
                ZagScopeBar(selection: $previewAppearance, titles: ["Light", "Dark"])
                    .frame(maxWidth: .infinity)
                    .frame(height: UISegmentedControl(items: ["Light", "Dark"]).intrinsicContentSize.height)
                    .accessibilityLabel("App Icon Preview Appearance")
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
            } header: {
                Text("Mode Preview")
            }
            .modifier(ZagAppIconSectionMargins(edges: .top))

            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(options) { option in
                        iconCard(option)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
            } header: {
                HStack(spacing: 8) {
                    Text("Variant")
                    ZagCountBadge(count: options.count)
                }
            }
            .modifier(ZagAppIconSectionMargins(edges: .bottom))
        }
        // NBList wraps Form internally; list-specific spacing modifiers
        // applied to NBList cannot reliably reach the Form. Attach them
        // directly to the Form which owns these native Sections.
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle(.localized("App Icon"))
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            currentIcon = UIApplication.shared.alternateIconName
            if !reduceMotion {
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                    gradientRotation = true
                }
            }
        }
    }
}

 
// The project supports older iOS deployment targets. Apply the native
// inter-section spacing API only where it exists; do not change either header.
private struct ZagAppIconCompactSections: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.listSectionSpacing(.custom(0))
        } else if #available(iOS 17.0, *) {
            content.listSectionSpacing(.custom(0))
        } else {
            content
        }
    }
}


// SwiftUI applies listSectionMargins to Section itself. Applying it to the
// enclosing Form did not reduce the section margins on iOS 26.
private struct ZagAppIconSectionMargins: ViewModifier {
    var edges: Edge.Set = .vertical

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.listSectionMargins(edges, 0)
        } else {
            content
        }
    }
}
