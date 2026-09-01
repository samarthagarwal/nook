import SwiftUI
import NookDesign
import NookCore

public struct KnowledgeView: View {
    @ObservedObject public var knowledgeEngineState: ObservableKnowledgeEngine
    public let onSelectCollection: (KnowledgeCollection) -> Void
    public let onAddCollection: () -> Void
    
    public init(
        knowledgeEngineState: ObservableKnowledgeEngine,
        onSelectCollection: @escaping (KnowledgeCollection) -> Void,
        onAddCollection: @escaping () -> Void
    ) {
        self.knowledgeEngineState = knowledgeEngineState
        self.onSelectCollection = onSelectCollection
        self.onAddCollection = onAddCollection
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Knowledge")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                
                Spacer()
                
                NookIconButton(systemName: "plus", isPrimary: true) {
                    onAddCollection()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Intro
            HStack {
                Text("Collections you add are read, indexed and searched entirely on this iPhone.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // Collections List
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(knowledgeEngineState.collections) { coll in
                        Button(action: {
                            onSelectCollection(coll)
                        }) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(coll.name)
                                        .font(NookTypography.cardTitleSerif)
                                        .foregroundColor(NookColors.ink)
                                    
                                    Spacer()
                                    
                                    Text(coll.count)
                                        .font(NookTypography.badge)
                                        .foregroundColor(NookColors.ink45)
                                }
                                
                                Text(coll.desc)
                                    .font(NookTypography.cardSub)
                                    .foregroundColor(NookColors.ink62)
                                
                                HStack(spacing: 6) {
                                    if coll.state == .ready {
                                        PrivacyDot()
                                        Text(coll.status)
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.local)
                                    } else {
                                        PrivacyRing()
                                        Text(coll.status)
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.external)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            .padding(16)
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}

public struct CollectionDetailView: View {
    public let collection: KnowledgeCollection
    public let documents: [KnowledgeDocument]
    public let isImporting: Bool
    public let onBack: () -> Void
    public let onStartChat: () -> Void
    public let onAddMarkdown: () -> Void

    public init(
        collection: KnowledgeCollection,
        documents: [KnowledgeDocument],
        isImporting: Bool = false,
        onBack: @escaping () -> Void,
        onStartChat: @escaping () -> Void,
        onAddMarkdown: @escaping () -> Void
    ) {
        self.collection = collection
        self.documents = documents
        self.isImporting = isImporting
        self.onBack = onBack
        self.onStartChat = onStartChat
        self.onAddMarkdown = onAddMarkdown
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                        Text("Knowledge")
                            .font(NookTypography.body)
                    }
                    .foregroundColor(NookColors.ink45)
                }
                .buttonStyle(.plain)
                
                Text(collection.name)
                    .font(NookTypography.detailTitle)
                    .foregroundColor(NookColors.ink)
                    .padding(.top, 4)
                
                Text("\(collection.count) · \(collection.status)")
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink45)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)

            Button(action: onAddMarkdown) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                    Text(isImporting ? "Indexing Markdown…" : "Add Markdown file")
                        .font(NookTypography.rowTitle)
                    Spacer()
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .foregroundColor(NookColors.ink70)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: NookRadius.card)
                        .fill(NookColors.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: NookRadius.card)
                        .strokeBorder(NookColors.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            
            // Documents List
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(documents) { doc in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(doc.name)
                                    .font(NookTypography.fileNameLg)
                                    .foregroundColor(NookColors.ink)
                                
                                Spacer()
                                
                                Text(doc.status)
                                    .font(NookTypography.badge)
                                    .foregroundColor(doc.progressPct != nil ? NookColors.external : NookColors.local)
                            }
                            
                            Text(doc.meta)
                                .font(NookTypography.meta)
                                .foregroundColor(NookColors.ink45)
                            
                            if let pct = doc.progressPct {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(NookColors.hairline)
                                            .frame(height: 3)
                                        
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(NookColors.external)
                                            .frame(width: geo.size.width * CGFloat(pct / 100.0), height: 3)
                                    }
                                }
                                .frame(height: 3)
                                .padding(.top, 2)
                            }
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
                    
                    // Shortcut dashed row
                    Button(action: onStartChat) {
                        HStack {
                            Spacer()
                            Text("Use this collection in a new chat")
                                .font(NookTypography.body)
                                .foregroundColor(NookColors.ink70)
                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .strokeBorder(
                                    Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.22),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}

@MainActor
public final class ObservableKnowledgeEngine: ObservableObject {
    @Published public var collections: [KnowledgeCollection] = []
    @Published public var documents: [KnowledgeDocument] = []
    @Published public var isImporting: Bool = false
    private let engine: KnowledgeEngine

    public init(engine: KnowledgeEngine) {
        self.engine = engine
        Task {
            await refreshCollections()
        }
    }

    public func refreshCollections() async {
        collections = await engine.getCollections()
    }

    public func loadDocuments(collectionId: String) async {
        documents = await engine.getDocuments(forCollectionId: collectionId)
    }

    public func importMarkdown(from url: URL, collectionId: String) async throws {
        isImporting = true
        defer { isImporting = false }
        _ = try await engine.importMarkdown(from: url, collectionId: collectionId)
        await loadDocuments(collectionId: collectionId)
        await refreshCollections()
    }
}
