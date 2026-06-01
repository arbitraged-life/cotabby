import SwiftUI

/// Settings pane showing local-only usage statistics.
struct AnalyticsPaneView: View {
    @ObservedObject private var analytics: UsageAnalytics = .shared
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section("Completion Statistics") {
                LabeledContent("Suggestions shown") {
                    Text("\(analytics.suggestionsShown)")
                        .monospacedDigit()
                }
                LabeledContent("Accepted") {
                    Text("\(analytics.suggestionsAccepted)")
                        .monospacedDigit()
                }
                LabeledContent("Rejected") {
                    Text("\(analytics.suggestionsRejected)")
                        .monospacedDigit()
                }
                LabeledContent("Acceptance rate") {
                    Text(analytics.acceptanceRate, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }

            Section("Productivity") {
                LabeledContent("Words saved") {
                    Text("\(analytics.wordsAccepted)")
                        .monospacedDigit()
                }
                LabeledContent("Characters saved") {
                    Text("\(analytics.charactersAccepted)")
                        .monospacedDigit()
                }
                LabeledContent("Words/day (avg)") {
                    Text(String(format: "%.1f", analytics.wordsPerDay))
                        .monospacedDigit()
                }
            }

            Section {
                LabeledContent("Tracking since") {
                    Text(analytics.trackingSince, style: .date)
                }
                Button("Reset Statistics", role: .destructive) {
                    showingResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all usage statistics?",
                    isPresented: $showingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        analytics.resetAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
