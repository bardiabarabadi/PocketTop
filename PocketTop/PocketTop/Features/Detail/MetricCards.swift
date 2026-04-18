import SwiftUI

// MARK: - Section card shell
//
// Common chrome for every section in the stacked-scroll detail layout.
// Kept minimal — visual consistency matters more than per-section styling
// at this scale.

struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    /// Optional trailing accessory (e.g. a per-core / overall toggle).
    @ViewBuilder let accessory: AnyView
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = AnyView(EmptyView())
        self.content = content()
    }

    init<Accessory: View>(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - Formatters
//
// File-scope funcs so both Detail and ProcessTable share one copy.

/// "1.3 GB" / "124 MB" / "512 KB" / "768 B". Uses 1024-based units (power-
/// of-two) which matches how Linux reports memory and RSS.
func formatBytes(_ bytes: Int64) -> String {
    let b = Double(max(0, bytes))
    let units: [(scale: Double, suffix: String)] = [
        (1024 * 1024 * 1024 * 1024, "TB"),
        (1024 * 1024 * 1024, "GB"),
        (1024 * 1024, "MB"),
        (1024, "KB")
    ]
    for (scale, suffix) in units where b >= scale {
        let v = b / scale
        return v < 10
            ? String(format: "%.1f %@", v, suffix)
            : String(format: "%.0f %@", v, suffix)
    }
    return "\(Int(b)) B"
}

func formatBytesPerSecond(_ bps: Int64) -> String {
    "\(formatBytes(bps))/s"
}

/// "42%", or "4.2%" when < 10 (one decimal of precision matters in the low
/// range where a twitch is a big relative change).
func formatPercent(_ pct: Double) -> String {
    let clamped = max(0, pct)
    if clamped < 10 {
        return String(format: "%.1f%%", clamped)
    } else {
        return "\(Int(clamped.rounded()))%"
    }
}

func formatWatts(_ w: Double) -> String {
    w < 10
        ? String(format: "%.1f W", max(0, w))
        : String(format: "%.0f W", max(0, w))
}

func formatCelsius(_ c: Double) -> String {
    String(format: "%.0f°", max(0, c))
}
