import SwiftUI
import NookDesign
import NookCore

public enum OnboardingStep {
    case hero
    case modelPick
    case downloading
    case ready
}

public struct OnboardingView: View {
    @State private var currentStep: OnboardingStep = .hero
    @State private var selectedTier: ModelTier = ModelTier.standardTiers[0]
    @State private var downloadProgress: Double = 0.0
    @State private var downloadError: String? = nil
    private let downloadModel: @Sendable (ModelTier, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let onComplete: (ModelTier) -> Void
    
    public init(
        downloadModel: @escaping @Sendable (ModelTier, @escaping @Sendable (Double) -> Void) async throws -> Void,
        onComplete: @escaping (ModelTier) -> Void
    ) {
        self.downloadModel = downloadModel
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ZStack {
            NookColors.paper.ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                switch currentStep {
                case .hero:
                    heroStepView
                case .modelPick:
                    modelPickStepView
                case .downloading:
                    downloadingStepView
                case .ready:
                    readyStepView
                }
                
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
        }
    }
    
    // MARK: - Step 1: Hero
    private var heroStepView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App Mark
            RoundedRectangle(cornerRadius: 10)
                .fill(NookColors.ink)
                .frame(width: 34, height: 34)
                .overlay(
                    Text("N")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundColor(NookColors.inkOnDark)
                )
            
            Text("Know.\nRemember.\nAct.")
                .font(NookTypography.heroDisplay)
                .foregroundColor(NookColors.ink)
                .lineSpacing(2)
            
            Text("Nook runs a capable AI model on this iPhone. Your chats, documents and memory stay here unless you send them somewhere yourself.")
                .font(.system(size: 15.5, weight: .regular))
                .foregroundColor(NookColors.ink62)
                .lineSpacing(5)
                .frame(maxWidth: 320, alignment: .leading)
            
            Spacer().frame(height: 16)
            
            NookPrimaryButton(title: "Get started") {
                withAnimation(.linear(duration: 0.2)) {
                    currentStep = .modelPick
                }
            }
            
            HStack {
                Spacer()
                Text("No account. No cloud by default.")
                    .font(NookTypography.badge)
                    .foregroundColor(NookColors.ink40)
                Spacer()
            }
        }
    }
    
    // MARK: - Step 2: Model Pick
    private var modelPickStepView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a model")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                
                Text("You can change this later, or keep more than one.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
            }
            
            VStack(spacing: 12) {
                ForEach(ModelTier.standardTiers) { tier in
                    let isSelected = selectedTier.id == tier.id
                    Button(action: {
                        selectedTier = tier
                    }) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(tier.name)
                                    .font(.system(size: 17, weight: isSelected ? .medium : .regular))
                                    .foregroundColor(NookColors.ink)
                                
                                Spacer()
                                
                                Text(tier.size)
                                    .font(NookTypography.badge)
                                    .foregroundColor(isSelected ? NookColors.local : NookColors.ink55)
                            }
                            
                            Text(tier.desc)
                                .font(NookTypography.cardSub)
                                .foregroundColor(NookColors.ink62)
                            
                            if isSelected {
                                HStack(spacing: 6) {
                                    ForEach(tier.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.local)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                RoundedRectangle(cornerRadius: NookRadius.tag)
                                                    .fill(NookColors.localSoft)
                                            )
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                .fill(NookColors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                .strokeBorder(isSelected ? NookColors.local : NookColors.hairlineStrong, lineWidth: isSelected ? 1.5 : 1)
                        )
                        .nookCardShadow()
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Spacer().frame(height: 12)
            
            NookPrimaryButton(title: setupButtonTitle) {
                withAnimation(.linear(duration: 0.2)) {
                    currentStep = .downloading
                }
                startDownload()
            }
        }
    }
    
    private var setupButtonTitle: String {
        selectedTier.shipsBundled ? "Continue" : "Download \(selectedTier.size)"
    }

    // MARK: - Step 3: Downloading
    private var downloadingStepView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(selectedTier.shipsBundled ? "Preparing" : "Downloading")
                .font(NookTypography.tabRootTitle)
                .foregroundColor(NookColors.ink)
            
            // Linear Progress Bar (6pt tall, radius 6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(NookColors.hairline)
                        .frame(height: 6)
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(NookColors.local)
                        .frame(width: geo.size.width * CGFloat(downloadProgress), height: 6)
                        .animation(.linear(duration: 0.2), value: downloadProgress)
                }
            }
            .frame(height: 6)
            
            Text("\(selectedTier.name) · staying on this iPhone   ·   \(Int(downloadProgress * 100))%")
                .font(NookTypography.badge)
                .foregroundColor(NookColors.ink55)
            
            Text(
                selectedTier.shipsBundled
                    ? "This model ships with Nook. No network connection needed."
                    : "Once it lands, Nook answers without a network connection. You can close the app; the download resumes."
            )
                .font(NookTypography.body)
                .foregroundColor(NookColors.ink55)
                .lineSpacing(4)
                .frame(maxWidth: 300, alignment: .leading)

            if let downloadError {
                Text(downloadError)
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.external)
                    .lineSpacing(3)
            }
            
            Spacer().frame(height: 40)
        }
    }
    
    private func startDownload() {
        downloadError = nil
        let tier = selectedTier
        let download = downloadModel
        Task.detached(priority: .userInitiated) {
            do {
                try await download(tier) { progress in
                    Task { @MainActor in
                        self.downloadProgress = min(1.0, progress)
                    }
                }
                await MainActor.run {
                    self.downloadProgress = 1.0
                    withAnimation(.linear(duration: 0.2)) {
                        self.currentStep = .ready
                    }
                }
            } catch {
                await MainActor.run {
                    self.downloadError = "Download failed. Check your connection and try again."
                }
            }
        }
    }
    
    // MARK: - Step 4: Ready ("You're set")
    private var readyStepView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("You're set")
                    .font(NookTypography.titleXL)
                    .foregroundColor(NookColors.ink)
                
                Text("Nook gets more useful as you give it things to know.")
                    .font(NookTypography.userBubble)
                    .foregroundColor(NookColors.ink62)
            }
            
            VStack(spacing: 10) {
                actionRow(title: "Add Knowledge", sub: "Documents Nook can search")
                actionRow(title: "Turn on a Skill", sub: "Teach it a way of working")
                actionRow(title: "Connect a service", sub: "Reach outside, with approval")
            }
            
            Spacer().frame(height: 12)
            
            NookPrimaryButton(title: "Start a chat") {
                onComplete(selectedTier)
            }
        }
    }
    
    private func actionRow(title: String, sub: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(NookColors.ink)
                Text(sub)
                    .font(NookTypography.cardSub)
                    .foregroundColor(NookColors.ink55)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NookColors.ink40)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .fill(NookColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
        )
        .nookCardShadow()
    }
}
