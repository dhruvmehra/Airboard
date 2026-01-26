//
//  PerformanceView.swift
//  Airboard
//
//  Real-time performance metrics display
//

import SwiftUI

struct PerformanceView: View {
    @ObservedObject private var monitor = PerformanceMonitor.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                headerView

                // Memory Usage Section
                memoryUsageView

                // Current Session Metrics
                if let session = monitor.currentSession {
                    sessionMetricsView(session: session)
                } else {
                    noSessionView
                }
            }
            .padding(16)
        }
        .frame(width: 380, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 24))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Performance Monitor")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Real-time metrics")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Memory Usage

    private var memoryUsageView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)

                Text("RAM Usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Text("\(formatMemory(monitor.memoryUsageMB)) / \(formatMemory(monitor.totalSystemMemoryMB))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            }

            // Memory bar with percentage
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.15))

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: memoryGradientColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * memoryPercentage)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("\(Int(memoryPercentage * 100))% of system RAM")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var memoryPercentage: Double {
        guard monitor.totalSystemMemoryMB > 0 else { return 0 }
        return min(monitor.memoryUsageMB / monitor.totalSystemMemoryMB, 1.0)
    }

    private var memoryGradientColors: [Color] {
        let percentage = memoryPercentage
        if percentage < 0.3 {
            return [.green, .green]
        } else if percentage < 0.5 {
            return [.green, .yellow]
        } else if percentage < 0.7 {
            return [.yellow, .orange]
        } else {
            return [.orange, .red]
        }
    }

    // MARK: - Session Metrics

    private func sessionMetricsView(session: PerformanceMonitor.SessionMetrics) -> some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.blue)

                Text("Latest Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Text(session.timestamp, style: .relative)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider()

            // Compact timing grid
            VStack(spacing: 8) {
                compactTimingRow(
                    icon: "mic.fill",
                    label: "Recording",
                    time: session.recordingDuration,
                    color: .red
                )

                compactTimingRow(
                    icon: "waveform",
                    label: "Transcription",
                    time: session.transcriptionTime,
                    color: .purple
                )

                compactTimingRow(
                    icon: "sparkles",
                    label: "Grammar",
                    time: session.grammarCorrectionTime,
                    color: .green
                )

                Divider()

                compactTimingRow(
                    icon: "sum",
                    label: "Total",
                    time: session.totalProcessingTime,
                    color: .blue,
                    isBold: true
                )
            }

            // Token counts in a compact row
            if session.inputTokenCount > 0 {
                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "number.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("Tokens:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    compactTokenBadge(
                        label: "In",
                        count: session.inputTokenCount,
                        color: .orange
                    )

                    compactTokenBadge(
                        label: "Out",
                        count: session.outputTokenCount,
                        color: .green
                    )
                }
            }

            // Compact text preview
            if !session.inputText.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Text("Text Sample")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    compactTextRow(label: "In", text: session.inputText)

                    if !session.outputText.isEmpty && session.outputText != session.inputText {
                        compactTextRow(label: "Out", text: session.outputText)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.08))
        )
    }

    private func compactTimingRow(icon: String, label: String, time: TimeInterval, color: Color, isBold: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: isBold ? .semibold : .regular))
                .foregroundColor(color)
                .frame(width: 14)

            Text(label)
                .font(.system(size: 12, weight: isBold ? .semibold : .regular))
                .foregroundColor(.primary)

            Spacer()

            Text(formatTime(time))
                .font(.system(size: 12, weight: isBold ? .semibold : .medium, design: .monospaced))
                .foregroundColor(color)
        }
    }

    private func compactTokenBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        )
    }

    private func compactTextRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 26, alignment: .leading)

            Text(text.prefix(80) + (text.count > 80 ? "..." : ""))
                .font(.system(size: 10))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.gray.opacity(0.08))
        )
    }

    // MARK: - No Session View

    private var noSessionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Session Data")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Text("Record audio to see metrics")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.05))
        )
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        if time < 0.001 {
            return "0ms"
        } else if time < 1.0 {
            return String(format: "%.0fms", time * 1000)
        } else {
            return String(format: "%.2fs", time)
        }
    }

    private func formatMemory(_ mb: Double) -> String {
        if mb < 1024 {
            return String(format: "%.0f MB", mb)
        } else {
            return String(format: "%.1f GB", mb / 1024.0)
        }
    }
}

// MARK: - Preview

#Preview {
    PerformanceView()
}
