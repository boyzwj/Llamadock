import LlamadockCore
import SwiftUI

struct BenchmarkView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.locale) private var locale

    @State private var selectedModelID = ""
    @State private var selectedContexts: Set<Int> = [1_024]
    @State private var selectedConcurrencies: Set<Int> = [1]
    @State private var generationTokens = 128
    @State private var results: [LlamaServerBenchmarkTrial] = []
    @State private var completedTrials = 0
    @State private var totalTrials = 0
    @State private var isRunning = false
    @State private var isWarmingUp = false
    @State private var errorMessage: String?
    @State private var benchmarkTask: Task<Void, Never>?

    private let contextOptions = [
        1_024,
        4_096,
        8_192,
        16_384,
        32_768,
        65_536,
        131_072,
        204_800,
    ]
    private let concurrencyOptions = [1, 2, 4, 8]

    var body: some View {
        LlamaDockPage {
            LlamaDockPageHeader(
                "Throughput Benchmark",
                subtitle:
                    "Measure llama-server prompt processing, generation, and continuous-batch throughput."
            ) {
                if isRunning {
                    Button(
                        "Cancel",
                        systemImage: "xmark",
                        role: .cancel,
                        action: cancelBenchmark
                    )
                } else {
                    Button(
                        "Run Benchmark",
                        systemImage: "play.fill",
                        action: startBenchmark
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                }
            }

            serverReadiness
            configuration

            if isRunning {
                benchmarkProgress
            }

            if let errorMessage {
                InlineNotice(errorMessage, tone: .failed)
            }

            if !results.isEmpty {
                summary
                resultTable
            } else if !isRunning {
                ContentUnavailableView {
                    Label(
                        "No Benchmark Results",
                        systemImage: "speedometer"
                    )
                } description: {
                    Text(
                        "Start the LlamaDock server, choose a model and workload, then run a local throughput sweep."
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .navigationTitle("Benchmark")
        .task {
            selectDefaultModelIfNeeded()
        }
        .onChange(of: appModel.enabledRouterProfiles) {
            selectDefaultModelIfNeeded()
        }
        .onDisappear {
            cancelBenchmark()
        }
    }

    @ViewBuilder
    private var serverReadiness: some View {
        if appModel.serverSnapshot.run == nil {
            InlineNotice(
                localized(
                    "Start the multi-model server before running a benchmark."
                ),
                systemImage: "server.rack"
            ) {
                Button("Open Dashboard") {
                    appModel.selectedSection = .overview
                }
            }
        } else if appModel.enabledRouterProfiles.isEmpty {
            InlineNotice(
                localized(
                    "Enable at least one model in Model Settings before running a benchmark."
                ),
                systemImage: "externaldrive.badge.exclamationmark"
            ) {
                Button("Open Model Settings") {
                    appModel.selectedSettingsTab = .models
                    appModel.selectedSection = .settings
                }
            }
        } else {
            InlineNotice(
                localized(
                    "Synthetic prompts stay on this Mac. Larger contexts and higher concurrency can consume substantial memory."
                ),
                systemImage: "lock.shield",
                tone: .ready
            )
        }
    }

    private var configuration: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 18) {
                Label("Benchmark Configuration", systemImage: "slider.horizontal.3")
                    .font(.title3.bold())

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                    GridRow {
                        configurationLabel(
                            "Model",
                            detail: "Requests are routed by the model identifier."
                        )

                        Picker("Model", selection: $selectedModelID) {
                            Text("Choose a Model").tag("")
                            ForEach(appModel.enabledRouterProfiles) { profile in
                                Text(
                                    "\(profile.name) — \(profile.router.identifier)"
                                )
                                .tag(profile.router.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 420)
                        .disabled(isRunning)
                    }

                    GridRow {
                        configurationLabel(
                            "Context Lengths",
                            detail: "Each selection creates one trial per concurrency level."
                        )

                        choiceRow(
                            values: contextOptions,
                            selection: $selectedContexts,
                            label: formattedContext
                        )
                    }

                    GridRow {
                        configurationLabel(
                            "Generation Length",
                            detail: "Requested output tokens per request."
                        )

                        HStack(spacing: 10) {
                            TextField(
                                "Tokens",
                                value: $generationTokens,
                                format: .number
                            )
                            .frame(width: 86)
                            .textFieldStyle(.roundedBorder)

                            Stepper(
                                "tokens",
                                value: $generationTokens,
                                in: 1...4_096,
                                step: 32
                            )
                            .labelsHidden()

                            Text("tokens")
                                .foregroundStyle(.secondary)
                        }
                        .disabled(isRunning)
                    }

                    GridRow {
                        configurationLabel(
                            "Concurrency",
                            detail: "Concurrent requests exercise llama-server continuous batching."
                        )

                        choiceRow(
                            values: concurrencyOptions,
                            selection: $selectedConcurrencies
                        ) {
                            $0 == 1
                                ? localized("Single")
                                : localized("\($0) requests")
                        }
                    }
                }

                Divider()

                HStack {
                    Label(
                        localized(
                            "\(plannedTrialCount) trials • up to \(formattedContext(maximumSelectedContext)) context • \(generationTokens) output tokens"
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if !results.isEmpty && !isRunning {
                        Button(
                            "Clear Results",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            results.removeAll()
                            errorMessage = nil
                        }
                    }
                }
            }
        }
    }

    private var benchmarkProgress: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        isWarmingUp
                            ? localized("Warming up model…")
                            : localized("Running throughput sweep…"),
                        systemImage: "speedometer"
                    )
                    .font(.headline)

                    Spacer()

                    Text("\(completedTrials) / \(totalTrials)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: Double(completedTrials),
                    total: Double(max(totalTrials, 1))
                )
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance Summary")
                .font(.title2.bold())

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170), spacing: 12),
                ],
                spacing: 12
            ) {
                MetricCard(
                    title: "Best Prompt Throughput",
                    value: formattedRate(
                        results.map(\.averagePromptTokensPerSecond).max()
                    ),
                    systemImage: "text.append",
                    tone: .active
                )
                MetricCard(
                    title: "Best Generation Throughput",
                    value: formattedRate(
                        results.map(\.averageGenerationTokensPerSecond).max()
                    ),
                    systemImage: "sparkles",
                    tone: .active
                )
                MetricCard(
                    title: "Best Batch Output",
                    value: formattedRate(
                        results.map(\.outputTokensPerSecond).max()
                    ),
                    systemImage: "rectangle.3.group",
                    tone: .ready
                )
                MetricCard(
                    title: "Lowest TPOT",
                    value: formattedMilliseconds(
                        results
                            .map(\.averageGenerationMillisecondsPerToken)
                            .filter { $0 > 0 }
                            .min()
                    ),
                    systemImage: "timer",
                    tone: .ready
                )
            }
        }
    }

    private var resultTable: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trial Results")
                            .font(.title3.bold())
                        Text(
                            "Prompt and generation rates come from llama-server timings; batch output is measured across wall-clock time."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(results.count) trials")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 22,
                        verticalSpacing: 10
                    ) {
                        GridRow {
                            tableHeader("Context")
                            tableHeader("Concurrency")
                            tableHeader("Actual Prompt")
                            tableHeader("Output")
                            tableHeader("Prompt TPS")
                            tableHeader("Generation TPS")
                            tableHeader("TPOT")
                            tableHeader("Batch Output TPS")
                            tableHeader("Wall Time")
                        }

                        Divider()
                            .gridCellColumns(9)

                        ForEach(results) { trial in
                            GridRow {
                                tableValue(
                                    formattedContext(
                                        trial.targetPromptTokens
                                    )
                                )
                                tableValue("×\(trial.concurrency)")
                                tableValue(
                                    formattedInteger(
                                        perRequest(
                                            trial.promptTokens,
                                            count: trial.requestCount
                                        )
                                    )
                                )
                                tableValue(
                                    formattedInteger(
                                        perRequest(
                                            trial.generatedTokens,
                                            count: trial.requestCount
                                        )
                                    )
                                )
                                tableValue(
                                    formattedNumber(
                                        trial.averagePromptTokensPerSecond
                                    )
                                )
                                tableValue(
                                    formattedNumber(
                                        trial.averageGenerationTokensPerSecond
                                    )
                                )
                                tableValue(
                                    formattedMilliseconds(
                                        trial.averageGenerationMillisecondsPerToken
                                    )
                                )
                                tableValue(
                                    formattedNumber(
                                        trial.outputTokensPerSecond
                                    )
                                )
                                tableValue(
                                    formattedSeconds(
                                        trial.wallMilliseconds
                                    )
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var canRun: Bool {
        appModel.serverSnapshot.run != nil
            && appModel.serviceStatus.isReachable
            && !selectedModelID.isEmpty
            && !selectedContexts.isEmpty
            && !selectedConcurrencies.isEmpty
            && (1...4_096).contains(generationTokens)
            && !isRunning
    }

    private var plannedTrialCount: Int {
        selectedContexts.count * selectedConcurrencies.count
    }

    private var maximumSelectedContext: Int {
        selectedContexts.max() ?? 0
    }

    private func startBenchmark() {
        guard
            canRun,
            let baseURL = appModel.serverSnapshot.run?.baseURL
        else {
            return
        }

        let model = selectedModelID
        let contexts = selectedContexts.sorted()
        let concurrencies = selectedConcurrencies.sorted()
        let outputTokens = generationTokens
        let runner = LlamaServerBenchmarkRunner()

        benchmarkTask?.cancel()
        results.removeAll()
        errorMessage = nil
        completedTrials = 0
        totalTrials = contexts.count * concurrencies.count
        isRunning = true
        isWarmingUp = true

        benchmarkTask = Task { @MainActor in
            defer {
                isRunning = false
                isWarmingUp = false
                benchmarkTask = nil
            }

            do {
                try await runner.warmUp(
                    baseURL: baseURL,
                    model: model
                )
                isWarmingUp = false

                for context in contexts {
                    for concurrency in concurrencies {
                        try Task.checkCancellation()
                        let trial = try await runner.runTrial(
                            baseURL: baseURL,
                            model: model,
                            targetPromptTokens: context,
                            generationTokens: outputTokens,
                            concurrency: concurrency
                        )
                        results.append(trial)
                        completedTrials += 1
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
        isRunning = false
        isWarmingUp = false
    }

    private func selectDefaultModelIfNeeded() {
        let identifiers = Set(
            appModel.enabledRouterProfiles.map(\.router.identifier)
        )
        guard !identifiers.contains(selectedModelID) else {
            return
        }
        selectedModelID =
            appModel.enabledRouterProfiles.first?.router.identifier
            ?? ""
    }

    private func configurationLabel(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 210, alignment: .leading)
    }

    private func choiceRow(
        values: [Int],
        selection: Binding<Set<Int>>,
        label: @escaping (Int) -> String
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 48, maximum: 72),
                    spacing: 8
                ),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(values, id: \.self) { value in
                let isSelected = selection.wrappedValue.contains(value)
                Button {
                    if isSelected {
                        guard selection.wrappedValue.count > 1 else {
                            return
                        }
                        selection.wrappedValue.remove(value)
                    } else {
                        selection.wrappedValue.insert(value)
                    }
                } label: {
                    Text(label(value))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            isSelected ? Color.white : Color.primary
                        )
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .accessibilityAddTraits(
                    isSelected ? .isSelected : []
                )
            }
        }
    }

    private func choiceRow(
        values: [Int],
        selection: Binding<Set<Int>>
    ) -> some View {
        choiceRow(
            values: values,
            selection: selection,
            label: { String($0) }
        )
    }

    private func tableHeader(
        _ title: LocalizedStringKey
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func tableValue(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospacedDigit())
            .fixedSize()
    }

    private func perRequest(_ value: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return value / count
    }

    private func formattedContext(_ tokens: Int) -> String {
        switch tokens {
        case 204_800:
            "200K"
        case let value where value >= 1_024:
            "\(value / 1_024)K"
        default:
            String(tokens)
        }
    }

    private func formattedRate(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        return "\(formattedNumber(value)) tok/s"
    }

    private func formattedMilliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }
        return String(format: "%.2f ms", value)
    }

    private func formattedSeconds(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else {
            return "—"
        }
        return String(format: "%.2f s", milliseconds / 1_000)
    }

    private func formattedNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "—"
        }
        if value >= 1_000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formattedInteger(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func localized(
        _ value: String.LocalizationValue
    ) -> String {
        appLocalizedString(value, locale: locale)
    }
}

#Preview {
    BenchmarkView()
        .environment(AppModel())
}
