import SwiftUI
import NookDesign
import NookCore

public enum OnboardingStep {
    case hero
    case ready
}

public struct OnboardingView: View {
    @State private var currentStep: OnboardingStep = .hero
    /// Completes onboarding and lands on the given tab (chat, knowledge, skills, or connect).
    private let onComplete: (NookTab) -> Void
    
    public init(onComplete: @escaping (NookTab) -> Void) {
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
            Image("AppLogo", bundle: .main)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            Text("Know.\nRemember.\nAct.")
                .nookHeroDisplay()
                .foregroundColor(NookColors.ink)
                .lineSpacing(2)
            
            Text("Nook is your private AI assistant. Your documents and memory stay on this device unless you send them somewhere yourself.")
                .font(.system(size: 15.5, weight: .regular))
                .foregroundColor(NookColors.ink62)
                .lineSpacing(5)
                .frame(maxWidth: 320, alignment: .leading)
            
            Spacer().frame(height: 16)
            
            NookPrimaryButton(title: "Get started") {
                withAnimation(.linear(duration: 0.2)) {
                    currentStep = .ready
                }
            }
            
            HStack {
                Spacer()
                Text("No account required.")
                    .font(NookTypography.badge)
                    .foregroundColor(NookColors.ink40)
                Spacer()
            }
        }
    }
    
    // MARK: - Step 2: Ready ("You're set")
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
                actionRow(
                    title: "Add Knowledge",
                    sub: "Documents Nook can search",
                    action: { onComplete(.knowledge) }
                )
                actionRow(
                    title: "Turn on a Skill",
                    sub: "Teach it a way of working",
                    action: { onComplete(.skills) }
                )
                actionRow(
                    title: "Connect a service",
                    sub: "Reach outside, with approval",
                    action: { onComplete(.connect) }
                )
            }
            
            Spacer().frame(height: 12)
            
            NookPrimaryButton(title: "Start a chat") {
                onComplete(.chat)
            }
        }
    }
    
    private func actionRow(title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
