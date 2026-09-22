import Combine
import Foundation

/// Модель окна: сохраняет API экранов и передаёт работу двум независимым
/// компонентам. Соединениями владеет manager, записью — executor.
@MainActor
final class RouterSession: ObservableObject {
    let connections: RouterConnectionManager
    private let executor: RouterPlanExecutor
    private var observation: AnyCancellable?
    let domainListUpdater = DomainListUpdateController(catalogProvider: { Store.shared.allSources })

    init(router: RouterProfile, dependencies: RouterSessionDependencies = .live) {
        connections = RouterConnectionManager(router: router, dependencies: dependencies)
        executor = RouterPlanExecutor(connections: connections)
        observation = connections.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var router: RouterProfile { connections.router }
    var activeRouterID: UUID { connections.activeRouterID }
    var status: ConnectionStatus { connections.status }
    var state: RouterState? { connections.state }
    var lastChange: RouterChange? { connections.lastChange }
    var progress: ProgressInfo? { connections.progress }
    var activity: String? { connections.activity }
    var operationHistory: OperationHistoryStore { connections.dependencies.operationHistory() }
    typealias BulkConnectOutcome = RouterConnectionManager.BulkConnectOutcome

    func beginOperation() -> RouterOperation { connections.beginOperation() }
    func isCurrent(_ operation: RouterOperation) -> Bool { connections.isCurrent(operation) }
    func isConnected(_ id: UUID) -> Bool { connections.isConnected(id) }
    func connectionStatus(for id: UUID) -> ConnectionStatus { connections.connectionStatus(for: id) }
    func activity(for id: UUID) -> String? { connections.activity(for: id) }
    func readState(for id: UUID) -> RouterState? { connections.readState(for: id) }
    func routersWithState() -> Set<UUID> { connections.routersWithState() }
    func isBusy(_ id: UUID) -> Bool { connections.isBusy(id) }
    func authBlock(_ id: UUID) -> String? { connections.authBlock(id) }
    func clearAuthBlock(_ id: UUID) { connections.clearAuthBlock(id) }
    func profileDidChange(_ profile: RouterProfile) { connections.profileDidChange(profile) }
    func credentialsDidChange(_ id: UUID) { connections.credentialsDidChange(id) }
    func forget(_ id: UUID) { connections.forget(id) }
    func forgetChange() { connections.forgetChange() }
    func disconnectAll() { connections.disconnectAll() }
    func switchTo(_ profile: RouterProfile) async { await connections.switchTo(profile) }
    func connect() async throws { try await connections.connect() }
    func connect(to profile: RouterProfile) async throws { try await connections.connect(to: profile) }
    func disconnect() async { await connections.disconnect() }
    func disconnect(_ id: UUID) async { await connections.disconnect(id) }
    func monitorConnections() async { await connections.monitorConnections() }
    func connectAll(_ profiles: [RouterProfile]) async -> BulkConnectOutcome {
        await connections.connectAll(profiles)
    }
    @discardableResult
    func connectAndRefresh(_ profile: RouterProfile) async throws -> RouterState {
        try await connections.connectAndRefresh(profile)
    }
    @discardableResult
    func refresh() async throws -> RouterState { try await connections.refresh() }
    @discardableResult
    func refresh(quiet: Bool) async throws -> RouterState { try await connections.refresh(quiet: quiet) }
    @discardableResult
    func refresh(owner: UUID) async throws -> RouterState { try await connections.refresh(owner: owner) }
    @discardableResult
    func refresh(operation: RouterOperation, quiet: Bool = false) async throws -> RouterState {
        try await connections.refresh(operation: operation, quiet: quiet)
    }
    @discardableResult
    func refreshLiveInterface(_ ident: String) async throws -> KeeneticInterface? {
        try await connections.refreshLiveInterface(ident)
    }
    func ping(interface: String, target: String, count: Int = 3,
              method: InterfaceProbeMethod = .icmp, port: Int? = nil) async throws -> InterfacePingResult {
        try await connections.ping(interface: interface, target: target, count: count, method: method, port: port)
    }
    func apply(plan: Plan, dryRun: Bool, saveConfig: Bool,
               preWriteCheck: (() throws -> Void)? = nil) async throws -> ApplyOutcome {
        try await executor.apply(plan: plan, dryRun: dryRun, saveConfig: saveConfig,
                                 preWriteCheck: preWriteCheck)
    }
    func withExclusiveWriteOperation<T>(operation: RouterOperation,
                                        _ body: @MainActor () async throws -> T) async throws -> T {
        try await executor.withExclusiveWriteOperation(operation: operation, body)
    }
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool = true) async throws -> String {
        try await executor.runCommands(commands, title: title, saveConfig: saveConfig)
    }
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool, owner: UUID) async throws -> String {
        try await executor.runCommands(commands, title: title, saveConfig: saveConfig, owner: owner)
    }
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool,
                     operation: RouterOperation) async throws -> String {
        try await executor.runCommands(commands, title: title, saveConfig: saveConfig, operation: operation)
    }
    func readConfigText() async throws -> String { try await connections.readConfigText() }
    func readConfigText(owner: UUID) async throws -> String { try await connections.readConfigText(owner: owner) }
    func readConfigText(operation: RouterOperation) async throws -> String {
        try await connections.readConfigText(operation: operation)
    }
    func readStartupConfig() async throws -> String { try await connections.readStartupConfig() }
    func readStartupConfig(owner: UUID) async throws -> String { try await connections.readStartupConfig(owner: owner) }
    func readStartupConfig(operation: RouterOperation) async throws -> String {
        try await connections.readStartupConfig(operation: operation)
    }
    func loadSource(_ spec: SourceSpec, forceRefresh: Bool,
                    requireFreshComplete: Bool = false) async throws -> SourceData {
        try await connections.loadSource(spec, forceRefresh: forceRefresh,
                                         requireFreshComplete: requireFreshComplete)
    }
    func setActivity(_ text: String?, owner: UUID? = nil) { connections.setActivity(text, owner: owner) }
    func setProgress(_ info: ProgressInfo?, owner: UUID? = nil) { connections.setProgress(info, owner: owner) }
    func bumpProgress(_ done: Int, owner: UUID? = nil) { connections.bumpProgress(done, owner: owner) }
    nonisolated func describe(_ error: Error) -> String {
        RouterConnectionManager.describeError(error)
    }
}
