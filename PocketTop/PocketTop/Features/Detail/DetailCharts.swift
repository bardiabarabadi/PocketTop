import SwiftUI
import Charts

// MARK: - Centered flow layout
//
// Wraps a variable number of fixed-width items into as many rows as fit the
// container width and centers each row horizontally. `LazyVGrid(.adaptive)`
// left-aligns the wrapped row, which makes a lone fifth ring slam to the
// edge on iPhone widths — this layout keeps the ragged row centered
// instead.

struct CenteredFlowLayout: Layout {
    var itemSpacing: CGFloat = 12
    var rowSpacing: CGFloat = 16
    /// Max width proposed to each subview. The overview rings target 74pt
    /// wide (`RingGauge.maxWidth`), so 90pt leaves headroom for the caption
    /// while letting sizeThatFits return the subview's natural size.
    var itemMaxWidth: CGFloat = 90

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let containerWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = layoutRows(subviews: subviews, containerWidth: containerWidth)
        let height = rows.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        // Claim the full proposed width when one is given so `placeSubviews`
        // centers each row within the actual container, not within the
        // natural row width (which would leave us left-aligned in the
        // parent and defeat the whole point of this layout).
        let reportedWidth: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            reportedWidth = proposed
        } else {
            reportedWidth = rows.map(\.width).max() ?? 0
        }
        return CGSize(width: reportedWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = layoutRows(subviews: subviews, containerWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for placement in row.items {
                subviews[placement.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(
                        width: placement.size.width,
                        height: placement.size.height
                    )
                )
                x += placement.size.width + itemSpacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Placement { let index: Int; let size: CGSize }
    private struct Row { let items: [Placement]; let width: CGFloat; let height: CGFloat }

    private func layoutRows(subviews: Subviews, containerWidth: CGFloat) -> [Row] {
        let proposal = ProposedViewSize(width: itemMaxWidth, height: nil)
        var rows: [Row] = []
        var current: [Placement] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(proposal)
            let next = current.isEmpty
                ? size.width
                : currentWidth + itemSpacing + size.width
            if !current.isEmpty && next > containerWidth {
                rows.append(Row(items: current, width: currentWidth, height: currentHeight))
                current = [Placement(index: index, size: size)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                current.append(Placement(index: index, size: size))
                currentWidth = next
                currentHeight = max(currentHeight, size.height)
            }
        }
        if !current.isEmpty {
            rows.append(Row(items: current, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

// MARK: - Ring gauge (Overview section)

/// Circular progress ring with a label + big value in the centre. Used for
/// the overview glance row (CPU / GPU / RAM / Disk I/O / Net) where a
/// single percent or bytes-per-second is enough signal.
struct RingGauge: View {
    let label: String
    /// 0.0 … 1.0. For rates (bytes/sec), caller normalises via a soft cap.
    let fraction: Double
    /// Already-formatted value shown in the middle (e.g. "42%", "3 MB/s").
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(value)
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 6)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 74)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Timeline chart (single series)

/// Renders one series over the 5-minute window. The x-axis labels show
/// wall-clock time (HH:mm:ss) so the user can cross-reference with other
/// logs or sessions. Line marks are thick enough to remain visible even
/// when all samples sit near zero.
struct TimelineChart: View {
    let samples: [HistorySample]
    let value: (HistorySample) -> Double
    let tint: Color
    /// Override the y-axis domain. `nil` lets Swift Charts auto-scale with
    /// a small minimum span so a flat idle line stays visually distinct.
    var yDomain: ClosedRange<Double>? = nil
    /// Y-axis label formatter (values in whatever unit `value` returns).
    var yLabel: (Double) -> String = { v in
        String(format: v < 10 ? "%.1f" : "%.0f", v)
    }
    var height: CGFloat = 110

    var body: some View {
        Chart(samples) { sample in
            LineMark(
                x: .value("t", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                y: .value("v", value(sample))
            )
            .foregroundStyle(tint)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis { wallClockAxis(samples: samples) }
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let v = mark.as(Double.self) {
                        Text(yLabel(v)).font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: effectiveDomain())
        .frame(height: height)
    }

    private func effectiveDomain() -> ClosedRange<Double> {
        if let d = yDomain { return d }
        let values = samples.map(value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        // Pad top by 15%; ensure a minimum visible span so a perfectly
        // flat series doesn't collapse against the baseline.
        let span = max(hi - min(0, lo), 1)
        let top = hi + max(span * 0.15, 1)
        return 0 ... top
    }
}

// MARK: - Timeline chart (two series: read+write, rx+tx)

struct DualTimelineChart: View {
    let samples: [HistorySample]
    let seriesA: (label: String, tint: Color, value: (HistorySample) -> Double)
    let seriesB: (label: String, tint: Color, value: (HistorySample) -> Double)
    var height: CGFloat = 120
    var yLabel: (Double) -> String = { v in formatBytesPerSecond(Int64(v)) }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("t", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("v", seriesA.value(sample))
                )
                .foregroundStyle(by: .value("series", seriesA.label))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                LineMark(
                    x: .value("t", Date(timeIntervalSince1970: TimeInterval(sample.ts))),
                    y: .value("v", seriesB.value(sample))
                )
                .foregroundStyle(by: .value("series", seriesB.label))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartForegroundStyleScale([
            seriesA.label: seriesA.tint,
            seriesB.label: seriesB.tint,
        ])
        .chartLegend(position: .top, alignment: .trailing, spacing: 8)
        .chartXAxis { wallClockAxis(samples: samples) }
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let v = mark.as(Double.self) {
                        Text(yLabel(v)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Per-core CPU chart

/// One line per logical core. Cores share a muted palette so you can see
/// imbalance without having to identify individual cores. Height matches
/// the single-line `TimelineChart` so toggling between Overall and Cores
/// doesn't resize the section.
struct PerCoreChart: View {
    let samples: [HistorySample]
    var height: CGFloat = 110

    var body: some View {
        Chart {
            ForEach(coreSeries(), id: \.core) { cs in
                ForEach(cs.points, id: \.ts) { p in
                    LineMark(
                        x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))),
                        y: .value("v", p.v),
                        series: .value("core", cs.core)
                    )
                    .foregroundStyle(Color.blue.opacity(0.45))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
        }
        .chartXAxis { wallClockAxis(samples: samples) }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let v = mark.as(Double.self) {
                        Text("\(Int(v))%").font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: 0 ... 100)
        .frame(height: height)
    }

    private struct Point { let ts: Int64; let v: Double }
    private struct Series { let core: Int; let points: [Point] }

    private func coreSeries() -> [Series] {
        guard let first = samples.first else { return [] }
        let n = first.cpu_per_core.count
        guard n > 0 else { return [] }
        var out: [Series] = []
        out.reserveCapacity(n)
        for core in 0 ..< n {
            var points: [Point] = []
            points.reserveCapacity(samples.count)
            for s in samples where s.cpu_per_core.count > core {
                points.append(Point(ts: s.ts, v: s.cpu_per_core[core]))
            }
            out.append(Series(core: core, points: points))
        }
        return out
    }
}

// MARK: - Shared x-axis formatting

/// Wall-clock x-axis. The chart stores x as `Date` so Swift Charts picks
/// sensible tick positions automatically (typically every 1–2 minutes for
/// a 5-min window). Labels render as HH:mm or HH:mm:ss depending on
/// zoom, matching iOS system time formatting.
@AxisContentBuilder
private func wallClockAxis(samples: [HistorySample]) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { mark in
        AxisGridLine()
        AxisValueLabel {
            if let d = mark.as(Date.self) {
                Text(d, format: wallClockFormat(samples: samples))
                    .font(.caption2)
            }
        }
    }
}

/// Pick HH:mm or HH:mm:ss depending on the visible span.
private func wallClockFormat(samples: [HistorySample]) -> Date.FormatStyle {
    guard let first = samples.first?.ts, let last = samples.last?.ts else {
        return .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
    }
    let span = last - first
    if span <= 60 {
        return .dateTime.hour(.defaultDigits(amPM: .omitted)).minute().second()
    }
    return .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
}
