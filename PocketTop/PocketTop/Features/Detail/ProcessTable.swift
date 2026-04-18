import SwiftUI

/// Top-N process table. Columns left-to-right: PID / USER / CPU% / MEM
/// (RSS) / NAME / CMD. Wrapped in a horizontal scroll so the CMD column
/// can render long command lines without truncation — you swipe the
/// table sideways to read the rest.
///
/// Default sort is CPU descending. Tapping a sortable column header
/// toggles ascending/descending; tapping a different column resets to
/// descending (standard spreadsheet UX).
///
/// Rows are tappable — the parent supplies an `onTap` closure that pops
/// a confirmationDialog with Terminate / Force kill / Cancel options.
struct ProcessTable: View {
    let processes: [ProcessInfo]
    @Binding var sortColumn: SortColumn
    @Binding var sortDescending: Bool
    let onTap: (ProcessInfo) -> Void

    enum SortColumn: Hashable { case pid, user, cpu, rss, name, cmd }

    // Fixed column widths. CMD is sized generously (900pt) so typical
    // Linux command lines with flags and paths fit without clipping; the
    // horizontal scroll view handles anything wider. Other columns are
    // sized so their contents never wrap — PID fits 8 digits (Linux
    // allocates up to pid_max≈4194304 but long-running containers can
    // push higher).
    private let wPID: CGFloat = 90
    private let wUser: CGFloat = 100
    private let wCPU: CGFloat = 74
    private let wMem: CGFloat = 88
    private let wName: CGFloat = 240
    private let wCmd: CGFloat = 900
    private var rowWidth: CGFloat {
        wPID + wUser + wCPU + wMem + wName + wCmd + 12 * 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .frame(width: rowWidth, alignment: .leading)
                    Divider()
                    if processes.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text("No process data yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(width: rowWidth)
                        .padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(processes.enumerated()), id: \.element.pid) { idx, proc in
                                Button {
                                    onTap(proc)
                                } label: {
                                    row(proc)
                                        .frame(width: rowWidth, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                if idx < processes.count - 1 {
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .tertiarySystemBackground))
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            sortableHeader(title: "PID",  column: .pid,  width: wPID,  align: .trailing)
            sortableHeader(title: "USER", column: .user, width: wUser, align: .leading)
            sortableHeader(title: "CPU%", column: .cpu,  width: wCPU,  align: .trailing)
            sortableHeader(title: "MEM",  column: .rss,  width: wMem,  align: .trailing)
            sortableHeader(title: "NAME", column: .name, width: wName, align: .leading)
            sortableHeader(title: "CMD",  column: .cmd,  width: wCmd,  align: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func sortableHeader(
        title: String,
        column: SortColumn,
        width: CGFloat,
        align: Alignment
    ) -> some View {
        Button {
            if sortColumn == column {
                sortDescending.toggle()
            } else {
                sortColumn = column
                // Numeric columns default to descending (biggest first);
                // string columns default to ascending (A→Z). Users expect
                // "first click on NAME" to land on the alphabetical top.
                switch column {
                case .pid, .cpu, .rss:
                    sortDescending = true
                case .user, .name, .cmd:
                    sortDescending = false
                }
            }
        } label: {
            HStack(spacing: 2) {
                if align == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                if align == .leading {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: width, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row

    private func row(_ proc: ProcessInfo) -> some View {
        HStack(spacing: 12) {
            // String(pid) renders raw digits — `Text("\(proc.pid)")` would
            // localise with thousand-separators ("3,332,866"), which reads
            // like a comma-separated value in a PID column.
            Text(String(proc.pid))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: wPID, alignment: .trailing)

            Text(proc.user)
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(width: wUser, alignment: .leading)

            Text(formatPercent(proc.cpu_pct))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: wCPU, alignment: .trailing)

            Text(formatBytes(proc.mem_rss))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: wMem, alignment: .trailing)

            Text(proc.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: wName, alignment: .leading)

            Text(proc.cmd.isEmpty ? proc.name : proc.cmd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: wCmd, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
