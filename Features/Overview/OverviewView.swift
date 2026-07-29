import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Overview")
                    .font(.largeTitle.bold())

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                    spacing: 16
                ) {
                    SummaryCard(
                        title: "Runtime",
                        value: "Not configured",
                        systemImage: "shippingbox"
                    )
                    SummaryCard(
                        title: "Models",
                        value: "No models",
                        systemImage: "externaldrive"
                    )
                    SummaryCard(
                        title: "Server",
                        value: "Stopped",
                        systemImage: "server.rack"
                    )
                }

                ContentUnavailableView(
                    "Set Up LlamaDock",
                    systemImage: "sparkles",
                    description: Text(
                        "Add a llama.cpp runtime and a GGUF model to start a local server."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            }
            .padding(28)
        }
        .navigationTitle("Overview")
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(value)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

#Preview {
    OverviewView()
        .frame(width: 800, height: 600)
}
