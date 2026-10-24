import SwiftUI

/// The cottage's plaster, timber and garden palette, shared by every companion panel.
enum CottageTheme {
    static let paper = Color(red: 0.98, green: 0.95, blue: 0.87)
    static let card = Color(red: 1.00, green: 0.98, blue: 0.93)
    static let ink = Color(red: 0.24, green: 0.20, blue: 0.15)
    static let mutedInk = Color(red: 0.43, green: 0.37, blue: 0.29)
    static let moss = Color(red: 0.31, green: 0.39, blue: 0.23)
    static let wood = Color(red: 0.43, green: 0.29, blue: 0.18)
    static let terracotta = Color(red: 0.65, green: 0.23, blue: 0.16)
    static let border = Color(red: 0.76, green: 0.66, blue: 0.50)
    static let leafPaper = Color(red: 0.91, green: 0.93, blue: 0.84)
    static let warningPaper = Color(red: 1.00, green: 0.91, blue: 0.79)
    static let heading = Font.system(.headline, design: .rounded, weight: .semibold)
    static let title = Font.system(.title2, design: .rounded, weight: .bold)
}

extension View {
    func cottageSurface() -> some View {
        self
            .foregroundStyle(CottageTheme.ink)
            .tint(CottageTheme.moss)
            .background(CottageTheme.paper)
            // The paper palette is intentionally light, including native form controls.
            .environment(\.colorScheme, .light)
    }

    func cottageCard(fill: Color = CottageTheme.card, warning: Bool = false) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(warning ? CottageTheme.terracotta : CottageTheme.border.opacity(0.65), lineWidth: warning ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
    }

    func cottageInput() -> some View {
        self.scrollContentBackground(.hidden)
            .padding(6)
            .cottageCard()
    }
}


/// The workbench keeps the companion palette while giving messages a quiet reading surface.
enum WorkbenchTheme {
    static let canvas = Color(red: 0.985, green: 0.982, blue: 0.966)
    static let sidebar = Color(red: 0.950, green: 0.954, blue: 0.927)
    static let line = Color(red: 0.875, green: 0.895, blue: 0.835)
    static let ink = Color(red: 0.20, green: 0.23, blue: 0.17)
    static let muted = Color(red: 0.47, green: 0.51, blue: 0.42)
    static let accent = Color(red: 0.32, green: 0.40, blue: 0.25)
    static let selection = Color(red: 0.89, green: 0.92, blue: 0.84)
    static let warning = Color(red: 0.985, green: 0.958, blue: 0.89)
}

extension View {
    func workbenchSurface() -> some View {
        self.foregroundStyle(WorkbenchTheme.ink).tint(WorkbenchTheme.accent)
            .background(WorkbenchTheme.canvas).environment(\.colorScheme, .light)
    }
    func workbenchPanel() -> some View {
        self.background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkbenchTheme.line.opacity(0.8)))
    }
}
