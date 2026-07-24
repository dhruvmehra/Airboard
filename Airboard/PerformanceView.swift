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
        .background(DS.Surface.panel)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 24))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.Accent.primary, DS.Accent.command],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Performance Monitor")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Label.primary)

                Text("Real-time metrics")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Label.secondary)
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
                    .foregroundColor(DS.Accent.warning)

                Text("RAM Usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Label.primary)

                Spacer()

                Text("\(formatMemory(monitor.memoryUsageMB)) / \(formatMemory(monitor.totalSystemMemoryMB))")
                    .font(DS.Typo.mono(12, .medium))
                    .foregroundColor(DS.Accent.warning)
            }

            // Memory bar with percentage
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: DS.Radius.r3)
                            .fill(DS.Fill.track)

                        RoundedRectangle(cornerRadius: DS.Radius.r3)
                            .fill(DS.Accent.primary)
                            .frame(width: geometry.size.width * memoryPercentage)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("\(Int(memoryPercentage * 100))% of system RAM")
                        .font(DS.Typo.rounded(10))
                        .foregroundColor(DS.Label.secondary)

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r10)
                .fill(DS.Tint.cardOrange)
        )
    }

    private var memoryPercentage: Double {
        guard monitor.totalSystemMemoryMB > 0 else { return 0 }
        return min(monitor.memoryUsageMB / monitor.totalSystemMemoryMB, 1.0)
    }

    // MARK: - Session Metrics

    private func sessionMetricsView(session: PerformanceMonitor.SessionMetrics) -> some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Accent.primary)

                Text("Latest Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Label.primary)

                Spacer()

                Text(session.timestamp, style: .relative)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Label.secondary)
            }

            Divider()

            // Compact timing grid
            VStack(spacing: 8) {
                compactTimingRow(
                    icon: "mic.fill",
                    label: "Recording",
                    time: session.recordingDuration,
                    color: DS.Accent.recording
                )

                compactTimingRow(
                    icon: "waveform",
                    label: "Transcription",
                    time: session.transcriptionTime,
                    color: DS.Accent.command
                )

                Divider()

                compactTimingRow(
                    icon: "sum",
                    label: "Total",
                    time: session.totalProcessingTime,
                    color: DS.Accent.primary,
                    isBold: true
                )
            }

            // Compact text preview
            if !session.inputText.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Label.secondary)

                        Text("Text Sample")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Label.secondary)
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
            RoundedRectangle(cornerRadius: DS.Radius.r10)
                .fill(DS.Tint.cardBlue)
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
                .foregroundColor(DS.Label.primary)

            Spacer()

            Text(formatTime(time))
                .font(DS.Typo.mono(12, isBold ? .semibold : .medium))
                .foregroundColor(color)
        }
    }

    private func compactTextRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(DS.Typo.mono(10, .medium))
                .foregroundColor(DS.Label.secondary)
                .frame(width: 26, alignment: .leading)

            Text(text.prefix(80) + (text.count > 80 ? "..." : ""))
                .font(.system(size: 10))
                .foregroundColor(DS.Label.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r5)
                .fill(DS.Fill.quaternary)
        )
    }

    // MARK: - No Session View

    private var noSessionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundColor(DS.Label.tertiary)

            Text("No Session Data")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Label.secondary)

            Text("Record audio to see metrics")
                .font(.system(size: 11))
                .foregroundColor(DS.Label.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r10)
                .fill(DS.Fill.quaternary)
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
