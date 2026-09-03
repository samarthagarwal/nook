import SwiftUI
import NookDesign
import NookCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ConnectionsView: View {
    @ObservedObject public var state: ObservableMCPState
    public let onSelectServer: (MCPServer) -> Void
    public let onAddServer: () -> Void
    
    public init(
        state: ObservableMCPState,
        onSelectServer: @escaping (MCPServer) -> Void,
        onAddServer: @escaping () -> Void
    ) {
        self.state = state
        self.onSelectServer = onSelectServer
        self.onAddServer = onAddServer
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connections")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                
                Spacer()
                
                Button(action: onAddServer) {
                    Text("Add")
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.local)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Intro
            HStack {
                Text("Outside services Nook can reach. Everything here leaves your device, so it asks first.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // Server List
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.servers) { server in
                        Button(action: {
                            onSelectServer(server)
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(server.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(NookColors.ink)
                                    
                                    Spacer()
                                    
                                    if server.isConnected {
                                        HStack(spacing: 5) {
                                            PrivacyRing()
                                            Text(server.toolsCountDescription)
                                                .font(NookTypography.badge)
                                                .foregroundColor(NookColors.external)
                                        }
                                    } else {
                                        Text("Not connected")
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.ink40)
                                    }
                                }
                                
                                Text(server.displayURL)
                                    .font(NookTypography.meta)
                                    .foregroundColor(NookColors.ink45)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if !server.tools.isEmpty {
                                    MCPConnectionToolChips(tools: server.toolsOrderedForChips)
                                        .padding(.top, 2)
                                }
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

/// One-row tool chips: full names, as many as fit, then `+N`. Enabled chips use external accent.
private struct MCPConnectionToolChips: View {
    let tools: [MCPToolEntry]
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(tools: tools, in: geo.size.width, spacing: spacing)
            HStack(spacing: spacing) {
                ForEach(fitted.visible) { tool in
                    Text(tool.name)
                        .font(NookTypography.badge)
                        .foregroundColor(tool.isEnabled ? NookColors.external : NookColors.ink45)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.tag)
                                .fill(tool.isEnabled ? NookColors.externalSoft : NookColors.fill)
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if fitted.overflow > 0 {
                    Text("+\(fitted.overflow)")
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.ink45)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.tag)
                                .fill(NookColors.fill)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 22)
    }

    private static func fit(
        tools: [MCPToolEntry],
        in width: CGFloat,
        spacing: CGFloat
    ) -> (visible: [MCPToolEntry], overflow: Int) {
        guard width > 0, !tools.isEmpty else {
            return ([], tools.count)
        }

        var visible: [MCPToolEntry] = []
        var used: CGFloat = 0

        for tool in tools {
            let chipW = textChipWidth(tool.name)
            let remainingAfter = tools.count - visible.count - 1
            let overflowLabel = remainingAfter > 0 ? "+\(remainingAfter)" : nil
            let overflowW = overflowLabel.map { textChipWidth($0) } ?? 0
            let gap = visible.isEmpty ? 0 : spacing
            let overflowGap = overflowLabel == nil ? 0 : spacing
            let needed = used + gap + chipW + overflowGap + overflowW

            if needed <= width + 0.5 {
                visible.append(tool)
                used += gap + chipW
            } else {
                break
            }
        }

        // If nothing fit, still show overflow so the row isn't blank.
        if visible.isEmpty {
            return ([], tools.count)
        }
        return (visible, tools.count - visible.count)
    }

    private static func textChipWidth(_ text: String) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        #elseif canImport(AppKit)
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        #else
        let textWidth = CGFloat(text.count) * 6.5
        #endif
        return ceil(textWidth) + 12 // horizontal padding
    }
}

public struct ServerDetailView: View {
    @State public var server: MCPServer
    public let onBack: () -> Void
    public let onSave: (MCPServer) -> Void
    /// Returns the refreshed server so this view can update its local copy.
    public var onReconnect: ((MCPServer) async throws -> MCPServer)?
    public var onRemove: ((MCPServer) -> Void)?
    
    @State private var selectedPolicyIndex: Int = 1 // Consequential
    @State private var isReconnecting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    
    private let policyOptions = MCPApprovalPolicy.allCases.map { $0.rawValue }
    
    public init(
        server: MCPServer,
        onBack: @escaping () -> Void,
        onSave: @escaping (MCPServer) -> Void,
        onReconnect: ((MCPServer) async throws -> MCPServer)? = nil,
        onRemove: ((MCPServer) -> Void)? = nil
    ) {
        self._server = State(initialValue: server)
        self.onBack = onBack
        self.onSave = onSave
        self.onReconnect = onReconnect
        self.onRemove = onRemove
        
        let initIndex = MCPApprovalPolicy.allCases.firstIndex(of: server.approvalPolicy) ?? 1
        self._selectedPolicyIndex = State(initialValue: initIndex)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .medium))
                            Text("Connections")
                                .font(NookTypography.body)
                        }
                        .foregroundColor(NookColors.ink45)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    if let onRemove {
                        Button(role: .destructive) {
                            onRemove(server)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(NookColors.external)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(NookColors.externalSoft))
                        }
                        .buttonStyle(.plain)
                        .disabled(isReconnecting)
                        .accessibilityLabel("Remove connection")
                    }
                }
                
                Text(server.name)
                    .font(NookTypography.detailTitle)
                    .foregroundColor(NookColors.ink)
                    .padding(.top, 4)
                
                Text("\(server.displayURL) · Streamable HTTP · header auth")
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink45)

                Text(server.isConnected ? server.toolsCountDescription : "Not connected")
                    .font(NookTypography.badge)
                    .foregroundColor(server.isConnected ? NookColors.external : NookColors.ink40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let onReconnect {
                        Button {
                            Task { await reconnect(using: onReconnect) }
                        } label: {
                            HStack(spacing: 8) {
                                Text(server.isConnected ? "Refresh tools" : "Connect")
                                if isReconnecting {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .font(NookTypography.rowTitle)
                            .foregroundColor(isReconnecting ? NookColors.ink40 : NookColors.local)
                        }
                        .buttonStyle(.plain)
                        .disabled(isReconnecting)

                        if let statusMessage {
                            Text(statusMessage)
                                .font(NookTypography.meta)
                                .foregroundColor(statusIsError ? .red : NookColors.ink62)
                        }
                    }

                    // Segmented Policy Control
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ASK BEFORE SENDING")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        NookSegmentedControl(options: policyOptions, selectedIndex: $selectedPolicyIndex)
                            .onChange(of: selectedPolicyIndex) { _, newIndex in
                                server.approvalPolicy = MCPApprovalPolicy.allCases[newIndex]
                                onSave(server)
                            }

                    }
                    
                    // Tool Rows
                    if server.tools.isEmpty {
                        Text(server.isConnected
                             ? "No tools reported by this server."
                             : "Connect to discover tools on this server.")
                            .font(NookTypography.meta)
                            .foregroundColor(NookColors.ink45)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TOOLS FOUND ON THIS SERVER")
                                .nookEyebrow()
                                .foregroundColor(NookColors.ink40)
                            
                            VStack(spacing: 8) {
                                ForEach(server.tools.indices, id: \.self) { idx in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(server.tools[idx].name)
                                                .font(NookTypography.fileName)
                                                .foregroundColor(NookColors.ink)
                                            
                                            Text(server.tools[idx].what)
                                                .font(NookTypography.meta)
                                                .foregroundColor(NookColors.ink55)
                                        }
                                        
                                        Spacer()
                                        
                                        // On = External ochre color
                                        NookToggle(
                                            isOn: $server.tools[idx].isEnabled,
                                            style: .external,
                                            accessibilityLabel: "Enable \(server.tools[idx].name)"
                                        )
                                        .onChange(of: server.tools[idx].isEnabled) { _, _ in
                                            onSave(server)
                                        }

                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .fill(NookColors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .strokeBorder(NookColors.hairline, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }

    private func reconnect(using onReconnect: (MCPServer) async throws -> MCPServer) async {
        guard !isReconnecting else { return }
        isReconnecting = true
        statusMessage = server.isConnected ? "Refreshing tools…" : "Connecting…"
        statusIsError = false
        defer { isReconnecting = false }
        do {
            let refreshed = try await onReconnect(server)
            server = refreshed
            let enabled = refreshed.tools.filter(\.isEnabled).count
            statusMessage = refreshed.isConnected
                ? "Connected · \(refreshed.tools.count) tools (\(enabled) on)"
                : "Finished, but server is not connected."
            statusIsError = !refreshed.isConnected
        } catch {
            statusIsError = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

@MainActor
public final class ObservableMCPState: ObservableObject {
    @Published public var servers: [MCPServer] = []
    private let client: MCPClient
    public var onToolsChanged: (() async -> Void)?

    public init(client: MCPClient) {
        self.client = client
        Task {
            await reload()
        }
    }

    public func reload() async {
        servers = await client.getServers()
    }

    public func updateServer(_ updated: MCPServer) {
        Task {
            await client.applyServerUpdate(updated)
            await reload()
            await onToolsChanged?()
        }
    }

    public func addAndConnect(name: String, url: String, authHeaderValue: String) async throws {
        _ = try await client.addAndConnect(
            name: name,
            url: url,
            authHeaderValue: authHeaderValue
        )
        await reload()
        await onToolsChanged?()
    }

    @discardableResult
    public func connect(serverId: String) async throws -> MCPServer {
        let server = try await client.connect(serverId: serverId)
        await reload()
        await onToolsChanged?()
        return await client.getServer(id: serverId) ?? server
    }

    public func disconnect(serverId: String) async {
        await client.disconnect(serverId: serverId)
        await reload()
        await onToolsChanged?()
    }

    public func removeServer(id: String) async {
        await client.removeServer(id: id)
        await reload()
        await onToolsChanged?()
    }
}
