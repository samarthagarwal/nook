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
        self.toolRegistry = toolRegistry ?? ToolRegistry(knowledgeEngine: knowledgeEngine)
        self.mcpClient = mcpClient
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
                    onComplete: { chosenTier in
                        AppPreferences.markOnboardingComplete(chosenTier: chosenTier)
                        self.isOnboardingComplete = true
                        self.runtimeStore.syncFromRuntime()
                        startNewChat()
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
                                self.activeSession?.persistConversationMetadata()
                                self.activeSession?.trimDisplayedMessages()
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
                            }
                        )
                    } else {
                        KnowledgeView(
                            knowledgeEngineState: knowledgeState,
                            onSelectCollection: { coll in
                                self.selectedCollection = coll
                            },
                            onAddCollection: {
                                showToast("Document picker opened on device")
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
                            }
                        )
                    } else {
                        ConnectionsView(
                            state: mcpState,
                            onSelectServer: { server in
                                self.selectedServer = server
                            },
                            onAddServer: {
                                showToast("Add MCP server configuration")
                            }
                        )
                    }
                }
                
                // Tab 5: Memory
                if selectedTab == .memory {
                    MemoryView(
                        state: memoryState,
                        onOpenSourceChat: { source in
                            self.selectedTab = .chat
                            if let first = conversations.first {
                                openConversation(first)
                            }
                        },
                        onForgetMemory: { item in
                            memoryState.forget(item: item)
                            showToast("Forgotten. The chat itself is untouched.")
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
        }
        .sheet(isPresented: $isScopeSheetOpen) {
            if let session = activeSession {
                ScopeSheet(
                    activeScope: Binding(
                        get: { session.conversation.activeKnowledgeScope },
                        set: { newScope in
                            session.conversation.activeKnowledgeScope = newScope
                            session.persistConversationMetadata()
                        }
                    ),
                    availableCollections: knowledgeState.collections.map(\.name),
                    onClose: {
                        self.isScopeSheetOpen = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(item: Binding<OutgoingApprovalPayload?>(
            get: { activeSession?.pendingApproval },
            set: { activeSession?.pendingApproval = $0 }
        )) { payload in
            ApprovalSheet(payload: payload) { action in
                activeSession?.resolveApproval(action: action)
            }
            .presentationDetents([.fraction(0.65)])
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
            mcpClient: mcpClient
        )
        self.activeSession = session
    }
    
    private func startNewChat(scopedTo: [String] = ["Project Alpha"]) {
        let newConvo = Conversation(
            title: "New chat",
            whenString: "now",
            snippet: "Ask anything",
            tags: scopedTo,
            activeKnowledgeScope: scopedTo
        )
        try? ChatStore.shared.saveConversation(newConvo)
        conversations.insert(newConvo, at: 0)
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

extension OutgoingApprovalPayload: Identifiable {
    public var id: String { toolName + serverUrl }
}
