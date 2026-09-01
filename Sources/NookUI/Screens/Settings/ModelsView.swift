import SwiftUI
import NookDesign
import NookCore
import NookRuntime

public struct ModelsView: View {
    @ObservedObject public var runtimeStore: ModelRuntimeStore
    public let onBack: () -> Void

    @State private var tierError: String?
    @State private var switchingTierId: String?
    @State private var storageBreakdown: StorageBreakdown = .empty

    public init(runtimeStore: ModelRuntimeStore, onBack: @escaping () -> Void) {
        self.runtimeStore = runtimeStore
        self.onBack = onBack
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                        Text("Settings")
                            .font(NookTypography.body)
                    }
                    .foregroundColor(NookColors.ink45)
                }
                .buttonStyle(.plain)
                
                Text("Models and storage")
                    .font(NookTypography.detailTitle)
                    .foregroundColor(NookColors.ink)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Curated Model Cards
                    VStack(spacing: 10) {
                        ForEach(ModelTier.standardTiers) { tier in
                            let isSelected = runtimeStore.activeTier.id == tier.id
                            let isSwitching = switchingTierId == tier.id
                            Button(action: {
                                guard switchingTierId == nil else { return }
                                tierError = nil
                                switchingTierId = tier.id
                                Task {
                                    do {
                                        try await runtimeStore.switchTier(tier)
                                    } catch {
                                        tierError = runtimeStore.userFacingErrorMessage(for: error)
                                    }
                                    switchingTierId = nil
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(tier.name)
                                            .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                                            .foregroundColor(NookColors.ink)

                                        Spacer()

                                        if isSwitching {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else if isSelected {
                                            Text("IN USE")
                                                .font(NookTypography.badge)
                                                .foregroundColor(NookColors.local)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: NookRadius.tag)
                                                        .fill(NookColors.localSoft)
                                                )
                                        } else {
                                            Text(tier.size)
                                                .font(NookTypography.badge)
                                                .foregroundColor(NookColors.ink45)
                                        }
                                    }

                                    Text(tier.longDesc)
                                        .font(NookTypography.cardSub)
                                        .foregroundColor(NookColors.ink62)
                                        .lineSpacing(3)
                                }
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                        .fill(NookColors.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                        .strokeBorder(isSelected ? NookColors.local : NookColors.hairline, lineWidth: isSelected ? 1.5 : 1)
                                )
                                .nookCardShadow()
                            }
                            .buttonStyle(.plain)
                            .disabled(isSwitching)
                        }
                    }

                    if case .downloading(let progress, let transfer) = runtimeStore.downloadState {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DOWNLOADING")
                                .nookEyebrow()
                                .foregroundColor(NookColors.ink40)
                            ProgressView(value: progress)
                                .tint(NookColors.local)
                            Text(downloadStatusLabel(progress: progress, transfer: transfer))
                                .font(NookTypography.badge)
                                .foregroundColor(NookColors.ink55)
                        }
                    }

                    if let tierError {
                        Text(tierError)
                            .font(NookTypography.meta)
                            .foregroundColor(NookColors.external)
                            .lineSpacing(3)
                    }
                    
                    storageSection

                    // Advanced Settings
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced")
                                    .font(NookTypography.rowTitle)
                                    .foregroundColor(NookColors.ink)
                                Text("Import a model, context length, sampling")
                                    .font(NookTypography.meta)
                                    .foregroundColor(NookColors.ink55)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(NookColors.ink40)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .fill(NookColors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .strokeBorder(NookColors.hairline, lineWidth: 1)
                        )
                        .nookCardShadow()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
        .onAppear {
            refreshStorageBreakdown()
        }
        .onChange(of: runtimeStore.downloadState) { _, _ in
            refreshStorageBreakdown()
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STORAGE ON THIS IPHONE")
                .nookEyebrow()
                .foregroundColor(NookColors.ink40)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    storageBarSegment(
                        bytes: storageBreakdown.modelsBytes,
                        total: max(storageBreakdown.nookBytes, 1),
                        width: geo.size.width,
                        color: NookColors.local
                    )
                    storageBarSegment(
                        bytes: storageBreakdown.knowledgeBytes,
                        total: max(storageBreakdown.nookBytes, 1),
                        width: geo.size.width,
                        color: NookColors.local.opacity(0.45)
                    )
                    storageBarSegment(
                        bytes: storageBreakdown.chatsBytes,
                        total: max(storageBreakdown.nookBytes, 1),
                        width: geo.size.width,
                        color: NookColors.external
                    )
                    if storageBreakdown.nookBytes == 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(NookColors.hairline)
                            .frame(height: 8)
                    }
                }
            }
            .frame(height: 8)

            Text("Bar shows Nook usage only — models, knowledge, and chats.")
                .font(NookTypography.badge)
                .foregroundColor(NookColors.ink40)
                .lineSpacing(3)

            VStack(alignment: .leading, spacing: 6) {
                storageLegendRow(
                    color: NookColors.local,
                    label: "Models",
                    bytes: storageBreakdown.modelsBytes
                )
                storageLegendRow(
                    color: NookColors.local.opacity(0.45),
                    label: "Knowledge",
                    bytes: storageBreakdown.knowledgeBytes
                )
                storageLegendRow(
                    color: NookColors.external,
                    label: "Chats",
                    bytes: storageBreakdown.chatsBytes
                )
                storageLegendRow(
                    color: NookColors.hairline,
                    label: "Free on device",
                    bytes: storageBreakdown.deviceFreeBytes
                )
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func storageBarSegment(
        bytes: Int64,
        total: Int64,
        width: CGFloat,
        color: Color
    ) -> some View {
        if bytes > 0, total > 0 {
            let segmentWidth = width * CGFloat(Double(bytes) / Double(total))
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: max(4, segmentWidth), height: 8)
        }
    }

    private func storageLegendRow(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(AppStorageUsage.format(bytes))")
                .font(NookTypography.badge)
                .foregroundColor(NookColors.ink55)
        }
    }

    private func refreshStorageBreakdown() {
        storageBreakdown = AppStorageUsage.measure()
    }

    private func downloadStatusLabel(progress: Double, transfer: DownloadTransferProgress?) -> String {
        if let transfer, transfer.totalBytes > 0 {
            let downloaded = AppStorageUsage.format(transfer.completedBytes)
            let total = AppStorageUsage.format(transfer.totalBytes)
            switch progress {
            case ..<0.05:
                return "Connecting… \(downloaded) of \(total)"
            case ..<0.85:
                return "Downloading… \(downloaded) of \(total)"
            default:
                return "Loading into memory… \(Int(progress * 100))%"
            }
        }

        switch progress {
        case ..<0.05:
            return "Connecting… \(Int(progress * 100))%"
        case ..<0.85:
            return "Downloading… \(Int(progress * 100))%"
        default:
            return "Loading into memory… \(Int(progress * 100))%"
        }
    }
}

public struct PaywallView: View {
    public let onClose: () -> Void
    public let onPurchase: () -> Void
    
    public init(onClose: @escaping () -> Void, onPurchase: @escaping () -> Void) {
        self.onClose = onClose
        self.onPurchase = onPurchase
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Close Button Top Right
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Title & Intro
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nook Pro")
                            .font(NookTypography.titleXL)
                            .foregroundColor(NookColors.ink)
                        
                        Text("Chat stays unlimited and free — you're supplying the compute. Pro is for making Nook deeply yours.")
                            .font(NookTypography.userBubble)
                            .foregroundColor(NookColors.ink62)
                            .lineSpacing(4)
                    }
                    
                    // Always Free List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ALWAYS FREE")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            bulletItem("Unlimited local chat, never metered", dotColor: NookColors.ink25)
                            bulletItem("A capable multimodal model", dotColor: NookColors.ink25)
                            bulletItem("Knowledge up to three collections", dotColor: NookColors.ink25)
                            bulletItem("Built-in Skills, and any Skill you import", dotColor: NookColors.ink25)
                            bulletItem("One connected service", dotColor: NookColors.ink25)
                        }
                    }
                    
                    // With Pro List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WITH PRO")
                            .nookEyebrow()
                            .foregroundColor(NookColors.local)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            bulletItem("Memory across every past chat", dotColor: NookColors.local)
                            bulletItem("Unlimited Knowledge collections and documents", dotColor: NookColors.local)
                            bulletItem("Page-image retrieval for charts and tables", dotColor: NookColors.local)
                            bulletItem("Unlimited connections and saved permissions", dotColor: NookColors.local)
                            bulletItem("Import your own models", dotColor: NookColors.local)
                            bulletItem("Export and backup controls", dotColor: NookColors.local)
                        }
                    }
                    
                    // Purchase CTA
                    VStack(spacing: 8) {
                        NookPrimaryButton(title: "Get Pro — £39 once") {
                            onPurchase()
                        }
                        
                        Text("One time. No subscription.")
                            .font(NookTypography.badge)
                            .foregroundColor(NookColors.ink40)
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
    
    private func bulletItem(_ text: String, dotColor: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            
            Text(text)
                .font(NookTypography.body)
                .foregroundColor(NookColors.ink)
        }
    }
}
