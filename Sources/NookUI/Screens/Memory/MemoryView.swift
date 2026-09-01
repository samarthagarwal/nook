import SwiftUI
import NookDesign
import NookCore

public struct MemoryView: View {
    @ObservedObject public var state: ObservableMemoryState
    public let onOpenSourceChat: (String) -> Void
    public let onForgetMemory: (MemoryItem) -> Void
    
    @State private var searchText: String = ""
    
    public init(
        state: ObservableMemoryState,
        onOpenSourceChat: @escaping (String) -> Void,
        onForgetMemory: @escaping (MemoryItem) -> Void
    ) {
        self.state = state
        self.onOpenSourceChat = onOpenSourceChat
        self.onForgetMemory = onForgetMemory
    }
    
    private var displayedMemories: [MemoryItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return state.memories
        }
        let lower = searchText.lowercased()
        return state.memories.filter {
            $0.subject.lowercased().contains(lower) ||
            $0.quote.lowercased().contains(lower) ||
            $0.kind.lowercased().contains(lower)
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Memory")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Intro
            HStack {
                Text("What Nook has picked up from past chats. Every item points back to where you said it.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(NookColors.ink40)
                
                TextField("Search your past chats", text: $searchText)
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(NookColors.ink40)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.pillLg)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.pillLg)
                    .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Suggestions when not searching
                    if searchText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TRY")
                                .nookEyebrow()
                                .foregroundColor(NookColors.ink40)
                            
                            VStack(spacing: 6) {
                                suggestionRow("that restaurant Sarah mentioned in London")
                                suggestionRow("what database did Sarah recommend")
                            }
                        }
                    }
                    
                    // Result Cards
                    VStack(spacing: 12) {
                        ForEach(displayedMemories) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                // Subject & Kind
                                HStack {
                                    Text(item.subject)
                                        .font(NookTypography.cardTitleSerif)
                                        .foregroundColor(NookColors.ink)
                                    
                                    Spacer()
                                    
                                    Text(item.kind)
                                        .font(NookTypography.badge)
                                        .foregroundColor(NookColors.ink40)
                                }
                                
                                // Quote with 2px localHairline left rule & 10pt indent
                                HStack(spacing: 10) {
                                    Rectangle()
                                        .fill(NookColors.localHairline)
                                        .frame(width: 2)
                                    
                                    Text(item.quote)
                                        .font(NookTypography.body)
                                        .foregroundColor(NookColors.ink70)
                                        .lineSpacing(4)
                                }
                                .padding(.vertical, 4)
                                
                                // Footer
                                HStack {
                                    Text(item.source)
                                        .font(NookTypography.badge)
                                        .foregroundColor(NookColors.ink45)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        onOpenSourceChat(item.source)
                                    }) {
                                        Text("Open")
                                            .font(NookTypography.badgeMedium)
                                            .foregroundColor(NookColors.local)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 10)
                                    
                                    Button(action: {
                                        onForgetMemory(item)
                                    }) {
                                        Text("Forget")
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.ink45)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.top, 4)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                    .fill(NookColors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                    .strokeBorder(NookColors.hairline, lineWidth: 1)
                            )
                            .nookCardShadow()
                        }
                    }
                    
                    // Footnote
                    HStack {
                        Spacer()
                        Text("Forgetting removes what Nook derived. The original chat stays untouched.")
                            .font(NookTypography.meta)
                            .foregroundColor(NookColors.ink45)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
    
    private func suggestionRow(_ text: String) -> some View {
        Button(action: {
            searchText = text
        }) {
            HStack {
                Text(text)
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 11))
                    .foregroundColor(NookColors.ink40)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.chip)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.chip)
                    .strokeBorder(NookColors.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
public final class ObservableMemoryState: ObservableObject {
    @Published public var memories: [MemoryItem] = []
    private let engine: MemoryEngine
    
    public init(engine: MemoryEngine) {
        self.engine = engine
        Task {
            let m = await engine.getAllMemories()
            self.memories = m
        }
    }
    
    public func forget(item: MemoryItem) {
        memories.removeAll { $0.id == item.id }
        Task {
            await engine.forget(memoryId: item.id)
        }
    }
}
