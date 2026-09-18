import SwiftUI
import AppKit

/// Shared visual vocabulary for the Imager glass theme.
/// CSS note: backdrop-filter / box-shadow are web concepts; in SwiftUI we use
/// `.regularMaterial` (the window) + `.ultraThinMaterial` (frosted) surfaces,
/// `.shadow(color:radius:)` for glows, and rgba-equivalent `Color(red:green:blue:)`.
///
/// Two selectable palettes: the original "slate glass" look and a "matte
/// black" one. Views draw all colors through `Theme`, which is re-pointed to
/// the active palette via `Theme.apply(_:)` (done on launch and whenever the
/// user switches themes in Settings).
struct ThemePalette {
    let canvasTop: Color
    let canvasBottom: Color
    let surface: Color
    let surfaceBorder: Color
    let accent: Color
    let accentGlow: Color
    let accentTint: Color
    let accentBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let isMatte: Bool
}

enum AppTheme: String, CaseIterable, Identifiable {
    case slateGlass
    case matteBlack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slateGlass: "Slate Glass"
        case .matteBlack: "Matte Black"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .slateGlass:
            ThemePalette(
                canvasTop: Color(red: 0.051, green: 0.067, blue: 0.133),      // #0D1117
                canvasBottom: Color(red: 0.086, green: 0.106, blue: 0.133),    // #161B22
                surface: Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.05),
                surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.10),
                accent: Color(red: 0.494, green: 0.792, blue: 0.541),          // #7ECA8A
                accentGlow: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.5),
                accentTint: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.15),
                accentBorder: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.40),
                textPrimary: Color.white,
                textSecondary: Color(red: 0.549, green: 0.580, blue: 0.619),  // #8B949E
                isMatte: false
            )
        case .matteBlack:
            ThemePalette(
                canvasTop: Color(red: 0.0, green: 0.0, blue: 0.0),            // #000000
                canvasBottom: Color(red: 0.035, green: 0.035, blue: 0.035),    // #090909
                surface: Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.045),
                surfaceBorder: Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.10),
                accent: Color(red: 0.494, green: 0.792, blue: 0.541),
                accentGlow: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.5),
                accentTint: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.15),
                accentBorder: Color(red: 0.494, green: 0.792, blue: 0.541, opacity: 0.40),
                textPrimary: Color.white,
                textSecondary: Color(red: 0.424, green: 0.424, blue: 0.424),  // #6C6C6C
                isMatte: true
            )
        }
    }
}

enum Theme {
    /// Page background gradient (dark charcoal blue → slate).
    private static var active = AppTheme.matteBlack

    static var canvasTop: Color { active.palette.canvasTop }
    static var canvasBottom: Color { active.palette.canvasBottom }

    /// Glass surfaces: near-black with ~5% white, blurred behind.
    static var surface: Color { active.palette.surface }
    static var surfaceBorder: Color { active.palette.surfaceBorder }

    /// Brand accent (soft green).
    static var accent: Color { active.palette.accent }
    static var accentGlow: Color { active.palette.accentGlow }
    static var accentTint: Color { active.palette.accentTint }
    static var accentBorder: Color { active.palette.accentBorder }

    /// Text.
    static var textPrimary: Color { active.palette.textPrimary }
    static var textSecondary: Color { active.palette.textSecondary }

    /// True when the active palette is a solid, non-glass look (matte black).
    static var isMatte: Bool { active.palette.isMatte }

    /// Panel background: frosted glass for glass palettes, solid matte surface
    /// for the matte palette (no blur/translucency).
    static var panelMaterial: AnyShapeStyle {
        isMatte ? AnyShapeStyle(canvasBottom) : AnyShapeStyle(.regularMaterial)
    }

    /// Popover/overlay background: frosted glass for glass palettes, opaque
    /// matte surface for the matte palette.
    static var popoverMaterial: AnyShapeStyle {
        isMatte ? AnyShapeStyle(Color(red: 0.07, green: 0.07, blue: 0.07)) : AnyShapeStyle(.ultraThinMaterial)
    }

    /// Blur behind custom glass surfaces (fallback path on older macOS).
    static let glassBlurRadius: CGFloat = 24

    static func apply(_ theme: AppTheme) {
        active = theme
    }
}

/// Root-level theme dressing for a panel: tints controls with the brand accent
/// and re-points `Theme` when the selection changes so every child view that
/// reads `Theme.*` repaints with the new palette.
struct ThemeAwareModifier: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .onChange(of: theme) { Theme.apply(theme) }
    }
}

extension View {
    func themeAware(_ theme: AppTheme) -> some View {
        modifier(ThemeAwareModifier(theme: theme))
    }
}

// MARK: - Liquid Glass helpers

enum GlassStyle {
    case regular
    case clear
}

extension View {
    /// Applies native Liquid Glass on macOS 26+, a custom translucent glass
    /// fallback on older systems, and a solid matte surface for the matte
    /// palette (no glass/blur on any macOS version).
    @ViewBuilder
    func glassSurface(_ style: GlassStyle = .regular, cornerRadius: CGFloat = 14) -> some View {
        if Theme.isMatte {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.surfaceBorder, lineWidth: 1)
                )
        } else if #available(macOS 26.0, *) {
            let material: Glass = style == .clear ? .clear : .regular
            self.glassEffect(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.surfaceBorder, lineWidth: 1)
                )
        }
    }
}
