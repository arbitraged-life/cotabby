import SwiftUI

/// File overview:
/// "Performance" detail pane of the redesigned Settings window. Owns a single opt-in toggle that
/// flips on per-request latency recording, plus a read-only table of the most recent generations.
/// The pane is intentionally inert until the user enables tracking — `SuggestionEngineRouter`
/// short-circuits the recorder whenever the toggle is off, so the table stays at whatever was
/// captured during the last enabled session.
struct PerformancePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var performanceMetricsStore: PerformanceMetricsStore

    var body: some View {
        SettingsPaneScaffold {
            Section("Tracking") {
                Toggle("Enable Performance Tracking", isOn: trackingEnabledBinding)
                    .help(
                        "When enabled, Cotabby records the timestamp, model, and elapsed time " +
                        "of every LLM request. Only the most recent " +
                        "\(PerformanceMetricsStore.maximumEntries) requests are retained."
                    )
            }

            Section {
                if performanceMetricsStore.entries.isEmpty {
                    Text(emptyStateMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    metricsTable
                }
            } header: {
                HStack {
                    Text(historyHeaderLabel)
                    Spacer()
                    if !performanceMetricsStore.entries.isEmpty {
                        Button("Clear") {
                            performanceMetricsStore.clear()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }

            modelComparisonSection
        }
    }

    // MARK: - Model Comparison

    @ObservedObject private var performanceTracker = ModelPerformanceTracker.shared

    @ViewBuilder
    private var modelComparisonSection: some View {
        if !performanceTracker.summaries.isEmpty {
            Section("Model Comparison") {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Model")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Median TTFT")
                            .frame(width: 90, alignment: .trailing)
                        Text("Tok/s")
                            .frame(width: 60, alignment: .trailing)
                        Text("Requests")
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    Divider()
                    ForEach(performanceTracker.summaries) { summary in
                        HStack(spacing: 12) {
                            Text(summary.modelName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(summary.medianTTFTMs) ms")
                                .frame(width: 90, alignment: .trailing)
                                .monospacedDigit()
                            Text(String(format: "%.1f", summary.medianDecodeTokensPerSecond))
                                .frame(width: 60, alignment: .trailing)
                                .monospacedDigit()
                            Text("\(summary.requestCount)")
                                .frame(width: 60, alignment: .trailing)
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        Divider().opacity(0.3)
                    }
                }

                Button("Clear Comparison Data") {
                    performanceTracker.clear()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - History table

    private var metricsTable: some View {
        // Newest-first reads more naturally for the "what just happened" use case. The underlying
        // store keeps insertion order so we reverse here without mutating the source of truth.
        let reversed = Array(performanceMetricsStore.entries.reversed())
        return VStack(spacing: 0) {
            tableHeader
            Divider()
            ForEach(Array(reversed.enumerated()), id: \.element.id) { index, entry in
                metricRow(for: entry)
                if index < reversed.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Time")
                .frame(width: 130, alignment: .leading)
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Context")
                .frame(width: 80, alignment: .trailing)
            Text("Duration")
                .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func metricRow(for entry: PerformanceMetricEntry) -> some View {
        HStack(spacing: 12) {
            Text(Self.timestampFormatter.string(from: entry.timestamp))
                .frame(width: 130, alignment: .leading)
                .monospacedDigit()
            Text(entry.modelName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            contextLabel(for: entry)
                .frame(width: 80, alignment: .trailing)
            Text("\(entry.latencyMs) ms")
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contextLabel(for entry: PerformanceMetricEntry) -> some View {
        if let chars = entry.contextCharacters {
            let displayKB = String(format: "%.1fK", Double(chars) / 1000.0)
            if entry.isContextTruncated {
                Text("⚠️ \(displayKB)")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .help("Context (\(chars) chars) likely exceeded model capacity")
            } else {
                Text(displayKB)
                    .monospacedDigit()
            }
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bindings

    private var trackingEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isPerformanceTrackingEnabled },
            set: { suggestionSettings.setPerformanceTrackingEnabled($0) }
        )
    }

    // MARK: - Helpers

    private var historyHeaderLabel: String {
        let count = performanceMetricsStore.entries.count
        let cap = PerformanceMetricsStore.maximumEntries
        if count == 0 {
            return "Recent Requests"
        }
        return "Recent Requests (\(count) of \(cap))"
    }

    private var emptyStateMessage: String {
        if suggestionSettings.isPerformanceTrackingEnabled {
            return "No requests recorded yet. Trigger a suggestion to start populating this list."
        }
        return "Performance tracking is off. Enable the toggle above to start recording requests."
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
