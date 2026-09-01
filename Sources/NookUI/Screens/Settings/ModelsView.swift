import SwiftUI
import NookDesign
import NookCore

public struct ModelsView: View {
    @Binding public var activeTier: ModelTier
    public let onBack: () -> Void
    
    public init(activeTier: Binding<ModelTier>, onBack: @escaping () -> Void) {
        self._activeTier = activeTier
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
                            let isSelected = activeTier.id == tier.id
                            Button(action: {
                                activeTier = tier
                            }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(tier.name)
                                            .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                                            .foregroundColor(NookColors.ink)
                                        
                                        Spacer()
                                        
                                        if isSelected {
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
                        }
                    }
                    
                    // Storage Breakdown Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STORAGE")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        // Stacked Bar (8pt)
                        HStack(spacing: 2) {
                            // Models: 38%
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NookColors.local)
                                .frame(width: 140, height: 8)
                            
                            // Knowledge: 12%
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NookColors.local.opacity(0.45))
                                .frame(width: 50, height: 8)
                            
                            // Chats: 6%
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NookColors.external)
                                .frame(width: 30, height: 8)
                            
                            // Available Space
                            RoundedRectangle(cornerRadius: 2)
                                .fill(NookColors.hairline)
                                .frame(height: 8)
                        }
                        
                        // Legend
                        HStack(spacing: 16) {
                            HStack(spacing: 5) {
                                Circle().fill(NookColors.local).frame(width: 5, height: 5)
                                Text("Models 6.5 GB")
                                    .font(NookTypography.badge)
                                    .foregroundColor(NookColors.ink55)
                            }
                            HStack(spacing: 5) {
                                Circle().fill(NookColors.local.opacity(0.45)).frame(width: 5, height: 5)
                                Text("Knowledge 2.1 GB")
                                    .font(NookTypography.badge)
                                    .foregroundColor(NookColors.ink55)
                            }
                            HStack(spacing: 5) {
                                Circle().fill(NookColors.external).frame(width: 5, height: 5)
                                Text("Chats 0.9 GB")
                                    .font(NookTypography.badge)
                                    .foregroundColor(NookColors.ink55)
                            }
                        }
                        .padding(.top, 4)
                    }
                    
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
