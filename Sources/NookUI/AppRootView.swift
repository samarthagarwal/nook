import SwiftUI
import UniformTypeIdentifiers
import NookDesign
import NookCore
import NookRuntime

public struct AppRootView: View {
    @State private var isOnboardingComplete: Bool = AppPreferences.isOnboardingComplete
    @State private var selectedTab: NookTab = .chat
    @StateObject private var runtimeStore: ModelRuntimeStore
    
    // Core Engine Instances
    @StateObject private var knowledgeState: ObservableKnowledgeEngine
    @StateObject private var skillState: ObservableSkillManager
    @StateObject private var mcpState: ObservableMCPState
    @StateObject private var memoryState: ObservableMemoryState
    
    private let knowledgeEngine: KnowledgeEngine
    private let memoryEngine: MemoryEngine
    private let skillManager: SkillManager
    private let toolRegistry: ToolRegistry
    private let mcpClient: MCPClient
    private let mcpToolRegistrar: MCPToolRegistrar
    
    // Navigation / Detail States
    @State private var conversations: [Conversation] = []
    @State private var activeSession: AgentSession? = nil
    @State private var selectedCollection: KnowledgeCollection? = nil
    @State private var selectedSkill: Skill? = nil
    @State private var selectedServer: MCPServer? = nil
    
    // Sheet Presentations
    @State private var isSettingsOpen: Bool = false
    @State private var isModelsOpen: Bool = false
    @State private var isPaywallOpen: Bool = false
    @State private var activeCitation: Citation? = nil
    @State private var isAttachSheetOpen: Bool = false
    @State private var isScopeSheetOpen: Bool = false
    @State private var isMarkdownImporterPresented: Bool = false
    @State private var markdownImportCollectionId: String? = nil
    @State private var activeToast: String? = nil
    @State private var isNewCollectionAlertPresented: Bool = false
    @State private var newCollectionName: String = ""
    @State private var newCollectionDesc: String = ""
    @State private var collectionPendingDelete: KnowledgeCollection? = nil
    @State private var documentPendingDelete: KnowledgeDocument? = nil
    @State private var conversationPendingDelete: Conversation? = nil
    @State private var serverPendingDelete: MCPServer? = nil
    @State private var memoryPendingForget: MemoryItem? = nil
    @State private var isAddMCPServerOpen: Bool = false
    
    public init(
        knowledgeEngine: KnowledgeEngine = KnowledgeEngine(),
        memoryEngine: MemoryEngine = MemoryEngine(),
        skillManager: SkillManager = SkillManager(),
        toolRegistry: ToolRegistry? = nil,
        mcpClient: MCPClient = MCPClient(),
        runtime: ModelRuntime? = nil
    ) {
        self.knowledgeEngine = knowledgeEngine
        self.memoryEngine = memoryEngine
        self.skillManager = skillManager
        let resolvedRegistry = toolRegistry ?? ToolRegistry(knowledgeEngine: knowledgeEngine)
        self.toolRegistry = resolvedRegistry
        self.mcpClient = mcpClient
        self.mcpToolRegistrar = MCPToolRegistrar(client: mcpClient, registry: resolvedRegistry)
        _runtimeStore = StateObject(wrappedValue: ModelRuntimeStore(runtime: runtime))
        
        _knowledgeState = StateObject(wrappedValue: ObservableKnowledgeEngine(engine: knowledgeEngine))
        _skillState = StateObject(wrappedValue: ObservableSkillManager(manager: skillManager))
        _mcpState = StateObject(wrappedValue: ObservableMCPState(client: mcpClient))
        _memoryState = StateObject(wrappedValue: ObservableMemoryState(engine: memoryEngine))
    }
    
    public var body: some View {
        ZStack {
            NookColors.paper.ignoresSafeArea()
            
            if !isOnboardingComplete {
                OnboardingView(
                    runtimeStore: runtimeStore,
                    downloadModel: { tier, progress in
                        try await self.runtimeStore.downloadModel(tier: tier, progressHandler: progress)
                    },
                    onComplete: { chosenTier, tab in
                        AppPreferences.markOnboardingComplete(chosenTier: chosenTier)
                        self.isOnboardingComplete = true
                        self.runtimeStore.syncFromRuntime()
                        self.selectedTab = tab
                        if tab == .chat {
                            startNewChat()
                        }
                    }
                )
            } else {
                mainContentView
            }
            
            // Toast Overlay
            if let toast = activeToast ?? activeSession?.toastMessage ?? runtimeStore.statusMessage {
                VStack {
                    Spacer()
                    ToastOverlay(message: toast)
                }
                .transition(.opacity)
                .animation(.linear(duration: 0.2), value: toast)
            }
        }
        .onAppear {
            loadConversations()
            mcpState.onToolsChanged = { [mcpToolRegistrar] in
                await mcpToolRegistrar.sync()
            }
            Task {
                await mcpToolRegistrar.sync()
            }
            print("[AppRootView] App launched. Runtime: \(type(of: runtimeStore.runtime)) (\(MLXPlatformSupport.runtimeLabel)). DownloadState: \(runtimeStore.downloadState)")
            if isOnboardingComplete {
                Task {
                    await runtimeStore.preloadActiveTierIfNeeded()
                }
            }
        }
        .onChange(of: runtimeStore.thermalAdvice) { _, advice in
            guard advice != .normal else { return }
            let message = advice == .throttled
                ? "This iPhone is running hot. Generation may pause until it cools."
                : "This iPhone is warming up. Responses may be slower."
            showToast(message)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookModelUnloadedDueToMemory)) { _ in
            activeSession?.trimDisplayedMessages(keepingLast: 40)
        }
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            if case .downloading(let progress, let transfer) = runtimeStore.downloadState {
                DownloadBannerView(
                    tierName: runtimeStore.displayTierName,
                    progress: progress,
                    transfer: transfer
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                // Tab 1: Chat Root or Active Chat Detail
                if selectedTab == .chat {
                    if let session = activeSession {
                        ChatView(
                            session: session,
                            runtimeStore: runtimeStore,
                            onBack: {
                                // Empty drafts were never written; delete is a no-op cleanup.
                                if let session = self.activeSession, session.messages.isEmpty {
                                    try? ChatStore.shared.deleteConversation(id: session.conversation.id)
                                } else {
                                    self.activeSession?.persistConversationMetadata()
                                    self.activeSession?.trimDisplayedMessages()
                                }
                                self.activeSession = nil
                                self.runtimeStore.releaseModelWhenIdle()
                                self.runtimeStore.resetMemoryPressureState()
                                loadConversations()
                            },
                            onOpenScope: {
                                self.isScopeSheetOpen = true
                            },
                            onOpenAttach: {
                                self.isAttachSheetOpen = true
                            },
                            onSelectCitation: { citation in
                                self.activeCitation = citation
                            },
                            onDelete: {
                                if let session = self.activeSession {
                                    conversationPendingDelete = session.conversation
                                }
                            }
                        )
                    } else {
                        ChatListView(
                            conversations: $conversations,
                            activeTier: runtimeStore.activeTier,
                            onSelectConversation: { convo in
                                openConversation(convo)
                            },
                            onNewChat: {
                                startNewChat()
                            },
                            onOpenSettings: {
                                self.isSettingsOpen = true
                            },
                            onDeleteConversation: { convo in
                                conversationPendingDelete = convo
                            }
                        )
                    }
                }
                
                // Tab 2: Knowledge
                if selectedTab == .knowledge {
                    if let coll = selectedCollection {
                        CollectionDetailView(
                            collection: coll,
                            documents: knowledgeState.documents,
                            isImporting: knowledgeState.isImporting,
                            onBack: {
                                self.selectedCollection = nil
                            },
                            onStartChat: {
                                self.selectedCollection = nil
                                self.selectedTab = .chat
                                startNewChat(scopedTo: [coll.name])
                            },
                            onAddMarkdown: {
                                markdownImportCollectionId = coll.id
                                isMarkdownImporterPresented = true
                            },
                            onDeleteDocument: { document in
                                documentPendingDelete = document
                            },
                            onDeleteCollection: {
                                collectionPendingDelete = coll
                            }
                        )
                    } else {
                        KnowledgeView(
                            knowledgeEngineState: knowledgeState,
                            onSelectCollection: { coll in
                                self.selectedCollection = coll
                            },
                            onAddCollection: {
                                newCollectionName = ""
                                newCollectionDesc = ""
                                isNewCollectionAlertPresented = true
                            },
                            onDeleteCollection: { coll in
                                collectionPendingDelete = coll
                            }
                        )
                    }
                }
                
                // Tab 3: Skills
                if selectedTab == .skills {
                    if let skill = selectedSkill {
                        SkillDetailView(
                            skill: skill,
                            onBack: {
                                self.selectedSkill = nil
                            },
                            onToggleSkill: { updated in
                                skillState.updateSkill(updated)
                            }
                        )
                    } else {
                        SkillsView(
                            state: skillState,
                            onSelectSkill: { skill in
                                self.selectedSkill = skill
                            },
                            onImportSkill: {
                                showToast("SKILL.md package imported")
                            }
                        )
                    }
                }
                
                // Tab 4: Connect (MCP)
                if selectedTab == .connect {
                    if let server = selectedServer {
                        ServerDetailView(
                            server: server,
                            onBack: {
                                self.selectedServer = nil
                            },
                            onSave: { updated in
                                mcpState.updateServer(updated)
                            },
                            onReconnect: { server in
                                let refreshed = try await mcpState.connect(serverId: server.id)
                                selectedServer = refreshed
                                return refreshed
                            },
                            onRemove: { server in
                                serverPendingDelete = server
                            }
                        )
                    } else {
                        ConnectionsView(
                            state: mcpState,
                            onSelectServer: { server in
                                self.selectedServer = server
                            },
                            onAddServer: {
                                isAddMCPServerOpen = true
                            }
                        )
                    }
                }
                
                // Tab 5: Memory
                if selectedTab == .memory {
                    MemoryView(
                        state: memoryState,
                        onOpenSourceChat: { conversationId in
                            self.selectedTab = .chat
                            if let match = conversations.first(where: { $0.id == conversationId }) {
                                openConversation(match)
                            } else if let loaded = try? ChatStore.shared.fetchConversation(id: conversationId) {
                                openConversation(loaded)
                            } else {
                                showToast("That chat is no longer on this iPhone.")
                            }
                        },
                        onForgetMemory: { item in
                            memoryPendingForget = item
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if activeSession == nil {
                NookTabBar(selectedTab: $selectedTab)
            }
        }
        // Sheets
        .sheet(isPresented: $isSettingsOpen) {
            SettingsView(
                activeTier: Binding(
                    get: { runtimeStore.activeTier },
                    set: { _ in }
                ),
                onOpenModels: {
                    self.isSettingsOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isModelsOpen = true
                    }
                },
                onOpenPaywall: {
                    self.isSettingsOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isPaywallOpen = true
                    }
                },
                onRebuildIndexes: {
                    self.isSettingsOpen = false
                    showToast("Rebuilt from your chats. Nothing you wrote was deleted.")
                },
                onExportData: {
                    self.isSettingsOpen = false
                    showToast("Export package saved locally.")
                },
                onEraseAllLocalData: {
                    eraseAllLocalData()
                },
                onClose: {
                    self.isSettingsOpen = false
                }
            )
        }
        .sheet(isPresented: $isAddMCPServerOpen) {
            AddMCPServerSheet { name, url, auth in
                try await mcpState.addAndConnect(
                    name: name,
                    url: url,
                    authHeaderValue: auth
                )
                showToast("Connected. Enable tools you want Nook to use.")
            }
        }
        .sheet(isPresented: $isModelsOpen) {
            ModelsView(runtimeStore: runtimeStore) {
                self.isModelsOpen = false
            }
        }
        .sheet(isPresented: $isPaywallOpen) {
            PaywallView(
                onClose: {
                    self.isPaywallOpen = false
                },
                onPurchase: {
                    self.isPaywallOpen = false
                    showToast("Nook Pro activated.")
                }
            )
        }
        .sheet(item: $activeCitation) { citation in
            CitationSheet(citation: citation) {
                self.activeCitation = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(NookColors.surface)
        }
        .sheet(isPresented: $isAttachSheetOpen) {
            AttachSheet(
                onSelectAttachment: { attachment in
                    showToast("Attached \(attachment)")
                },
                onClose: {
                    self.isAttachSheetOpen = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(NookColors.surface)
        }
        .sheet(isPresented: $isScopeSheetOpen) {
            if let session = activeSession {
                ScopeSheet(
                    session: session,
                    availableCollections: knowledgeState.collections.map(\.name),
                    onClose: {
                        self.isScopeSheetOpen = false
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(NookColors.surface)
            }
        }
        .alert("New collection", isPresented: $isNewCollectionAlertPresented) {
            TextField("Name", text: $newCollectionName)
            TextField("Subtitle", text: $newCollectionDesc)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = newCollectionDesc.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await knowledgeState.createCollection(name: name, desc: desc)
                        showToast("Created \(name)")
                    } catch {
                        showToast("Couldn’t create collection.")
                    }
                }
            }
        } message: {
            Text("Name is required. Subtitle appears under the title in your Knowledge list.")
        }
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { conversationPendingDelete != nil },
                set: { if !$0 { conversationPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                conversationPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let conversation = conversationPendingDelete else { return }
                conversationPendingDelete = nil
                do {
                    try ChatStore.shared.deleteConversation(id: conversation.id)
                    conversations.removeAll { $0.id == conversation.id }
                    memoryState.reload()
                    if activeSession?.conversation.id == conversation.id {
                        activeSession = nil
                        runtimeStore.releaseModelWhenIdle()
                        runtimeStore.resetMemoryPressureState()
                    }
                    showToast("Deleted chat")
                } catch {
                    showToast("Couldn’t delete chat.")
                }
            }
        } message: {
            if let conversation = conversationPendingDelete {
                let title = ChatStore.plainText(from: conversation.title)
                Text("“\(title)” will be removed from this iPhone. Memories from this chat will be removed too.")
            }
        }
        .alert(
            "Remove connection?",
            isPresented: Binding(
                get: { serverPendingDelete != nil },
                set: { if !$0 { serverPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                serverPendingDelete = nil
            }
            Button("Remove", role: .destructive) {
                guard let server = serverPendingDelete else { return }
                serverPendingDelete = nil
                Task {
                    await mcpState.removeServer(id: server.id)
                    if selectedServer?.id == server.id {
                        selectedServer = nil
                    }
                    showToast("Removed \(server.name).")
                }
            }
        } message: {
            if let server = serverPendingDelete {
                Text("“\(server.name)” will be disconnected and removed from this iPhone. You can add it again later.")
            }
        }
        .alert(
            "Forget this memory?",
            isPresented: Binding(
                get: { memoryPendingForget != nil },
                set: { if !$0 { memoryPendingForget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                memoryPendingForget = nil
            }
            Button("Forget", role: .destructive) {
                guard let item = memoryPendingForget else { return }
                memoryPendingForget = nil
                memoryState.forget(item: item)
                showToast("Forgotten. The chat itself is untouched.")
            }
        } message: {
            Text("Nook will stop using this derived memory. The original chat stays on this iPhone.")
        }
        .alert(
            "Delete collection?",
            isPresented: Binding(
                get: { collectionPendingDelete != nil },
                set: { if !$0 { collectionPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                collectionPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let collection = collectionPendingDelete else { return }
                collectionPendingDelete = nil
                Task {
                    do {
                        try await knowledgeState.deleteCollection(id: collection.id)
                        if selectedCollection?.id == collection.id {
                            selectedCollection = nil
                        }
                        showToast("Deleted \(collection.name)")
                    } catch {
                        showToast("Couldn’t delete collection.")
                    }
                }
            }
        } message: {
            if let collection = collectionPendingDelete {
                Text("“\(collection.name)” and all of its documents will be removed from this iPhone.")
            }
        }
        .alert(
            "Delete document?",
            isPresented: Binding(
                get: { documentPendingDelete != nil },
                set: { if !$0 { documentPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                documentPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let document = documentPendingDelete else { return }
                documentPendingDelete = nil
                Task {
                    do {
                        try await knowledgeState.deleteDocument(
                            id: document.id,
                            collectionId: document.collectionId
                        )
                        if let updated = knowledgeState.collections.first(where: { $0.id == document.collectionId }) {
                            selectedCollection = updated
                        }
                        showToast("Deleted \(document.name)")
                    } catch {
                        showToast("Couldn’t delete document.")
                    }
                }
            }
        } message: {
            if let document = documentPendingDelete {
                Text("“\(document.name)” will be removed from this collection and its index.")
            }
        }
        .onChange(of: selectedCollection?.id) { _, collectionId in
            guard let collectionId else { return }
            Task {
                await knowledgeState.loadDocuments(collectionId: collectionId)
            }
        }
        .fileImporter(
            isPresented: $isMarkdownImporterPresented,
            allowedContentTypes: Self.markdownImportTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first,
                  let collectionId = markdownImportCollectionId else { return }
            Task {
                do {
                    try await knowledgeState.importMarkdown(from: url, collectionId: collectionId)
                    if let coll = selectedCollection,
                       let updated = knowledgeState.collections.first(where: { $0.id == coll.id }) {
                        selectedCollection = updated
                    }
                    showToast("Indexed \(url.lastPathComponent)")
                } catch {
                    showToast(error.localizedDescription)
                }
            }
        }
        .onChange(of: runtimeStore.downloadState) { oldState, newState in
            if case .downloading = oldState, case .ready = newState {
                showToast("\(runtimeStore.activeTier.name) is ready.")
            }
        }
    }
    
    private static var markdownImportTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    private func loadConversations() {
        try? ChatStore.shared.deleteEmptyConversations()
        conversations = (try? ChatStore.shared.fetchConversations()) ?? []
    }
    
    private func openConversation(_ convo: Conversation) {
        let messages = (
            try? ChatStore.shared.fetchRecentMessages(
                conversationId: convo.id,
                limit: AgentSession.maxMessagesInMemory
            )
        ) ?? []
        runtimeStore.resetMemoryPressureState()
        let session = AgentSession(
            conversation: convo,
            messages: messages,
            knowledgeEngine: knowledgeEngine,
            memoryEngine: memoryEngine,
            skillManager: skillManager,
            toolRegistry: toolRegistry,
            mcpClient: mcpClient,
            mcpToolRegistrar: mcpToolRegistrar
        )
        self.activeSession = session
    }
    
    private func startNewChat(scopedTo: [String] = []) {
        // Keep drafts in memory only until the first message is sent.
        let newConvo = Conversation(
            title: "New chat",
            whenString: "now",
            snippet: "Ask anything",
            tags: scopedTo,
            activeKnowledgeScope: scopedTo
        )
        openConversation(newConvo)
    }
    
    private func eraseAllLocalData() {
        do {
            try NookLocalDataReset.eraseAll()
            conversations = []
            activeSession = nil
            selectedCollection = nil
            isSettingsOpen = false
            Task {
                await knowledgeState.refreshCollections()
                knowledgeState.documents = []
            }
            showToast("All chats and Knowledge erased.")
        } catch {
            showToast("Could not erase local data.")
            print("[AppRootView] Erase failed: \(error)")
        }
    }

    private func showToast(_ message: String) {
        self.activeToast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.activeToast == message {
                self.activeToast = nil
            }
        }
    }
}
