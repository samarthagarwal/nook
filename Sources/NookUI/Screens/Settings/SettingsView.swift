import SwiftUI
import NookDesign
import NookCore

public struct SettingsView: View {
    @Binding public var activeTier: ModelTier
    public let onOpenModels: () -> Void
    public let onOpenPaywall: () -> Void
    public let onRebuildIndexes: () -> Void
    public let onExportData: () -> Void
    public let onEraseAllLocalData: () -> Void
    public let onClose: () -> Void
    
    @State private var keepOnDevice: Bool = true
    @State private var logOutgoing: Bool = true
    @State private var shareUsage: Bool = false
    @State private var showEraseConfirmation: Bool = false
    
    public init(
        activeTier: Binding<ModelTier>,
        onOpenModels: @escaping () -> Void,
        onOpenPaywall: @escaping () -> Void,
        onRebuildIndexes: @escaping () -> Void,
        onExportData: @escaping () -> Void,
        onEraseAllLocalData: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self._activeTier = activeTier
        self.onOpenModels = onOpenModels
        self.onOpenPaywall = onOpenPaywall
        self.onRebuildIndexes = onRebuildIndexes
        self.onExportData = onExportData
        self.onEraseAllLocalData = onEraseAllLocalData
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(NookTypography.sheetTitle)
                    .foregroundColor(NookColors.ink)
                
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
            .padding(.top, 18)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(spacing: 20) {
                    // Pro Banner Card
                    Button(action: onOpenPaywall) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Get Nook Pro")
                                    .font(NookTypography.cardTitleSerif)
                                    .foregroundColor(NookColors.inkOnDark)
                                
                                Text("Memory, unlimited Knowledge, more connections")
                                    .font(NookTypography.cardSub)
                                    .foregroundColor(NookColors.inkOnDark.opacity(0.65))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(NookColors.inkOnDark.opacity(0.5))
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                .fill(NookColors.ink)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    // Privacy Toggles
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PRIVACY")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        VStack(spacing: 8) {
                            toggleRow(
                                title: "Keep everything on device",
                                sub: "Chats, documents and memory never sync",
                                isOn: $keepOnDevice
                            )
                            toggleRow(
                                title: "Log outgoing calls",
                                sub: "A record of what left, and when",
                                isOn: $logOutgoing
                            )
                            toggleRow(
                                title: "Share usage data",
                                sub: "Off. Nook works without it",
                                isOn: $shareUsage
                            )
                        }
                    }
                    
                    // Data & Models Nav Rows
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DATA")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        VStack(spacing: 8) {
                            navRow(
                                title: "Models and storage",
                                sub: "\(activeTier.name) in use · ~4.5 GB catalog",
                                action: onOpenModels
                            )
                            navRow(
                                title: "Rebuild derived indexes",
                                sub: "Deletes memory and search indexes, keeps chats",
                                action: onRebuildIndexes
                            )
                            navRow(
                                title: "Export everything",
                                sub: "Chats, Knowledge and grants as files",
                                action: onExportData
                            )
                            Button(action: {
                                showEraseConfirmation = true
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Erase chats and Knowledge")
                                            .font(NookTypography.rowTitle)
                                            .foregroundColor(NookColors.external)
                                        Text("Deletes all conversations and indexed documents")
                                            .font(NookTypography.meta)
                                            .foregroundColor(NookColors.ink55)
                                    }
                                    Spacer()
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
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
        .alert("Erase all local data?", isPresented: $showEraseConfirmation) {
            Button("Erase", role: .destructive) {
                onEraseAllLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every chat and indexed document from this iPhone. It cannot be undone.")
        }
    }
    
    private func toggleRow(title: String, sub: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NookTypography.rowTitle)
                    .foregroundColor(NookColors.ink)
                Text(sub)
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink55)
            }
            Spacer()
            NookToggle(isOn: isOn, style: .local, accessibilityLabel: title)
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
    
    private func navRow(title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.ink)
                    Text(sub)
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
        .buttonStyle(.plain)
    }
}
