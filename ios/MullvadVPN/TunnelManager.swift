//
//  TunnelManager.swift
//  MullvadVPN
//
//  Created by pronebird on 25/09/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import NetworkExtension
import os

enum MapConnectionStatusError: ChainedError {
    /// A failure to perform the IPC request because the tunnel IPC is already deallocated
    case missingIpc

    /// A failure to send a subsequent IPC request to collect more information, such as tunnel
    /// connection info.
    case ipcRequest(PacketTunnelIpc.Error)

    /// A failure to map the status because the unknown variant of `NEVPNStatus` was given.
    case unknownStatus(NEVPNStatus)

    /// A failure to map the status because the `NEVPNStatus.invalid` variant was given
    /// This happens when attempting to start a tunnel with configuration that does not exist
    /// anymore in system preferences.
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .missingIpc:
            return "Missing IPC"

        case .ipcRequest:
            return "IPC request error"

        case .unknownStatus(let status):
            return "Unknown NEVPNStatus: \(status)"

        case .invalidConfiguration:
            return "Invalid VPN configuration"
        }
    }
}

/// A enum that describes the tunnel state
enum TunnelState: Equatable {
    /// Connecting the tunnel
    case connecting

    /// Connected the tunnel
    case connected(TunnelConnectionInfo)

    /// Disconnecting the tunnel
    case disconnecting

    /// Disconnected the tunnel
    case disconnected

    /// Reconnecting the tunnel. Normally this state appears in response to changing the
    /// relay constraints and asking the running tunnel to reload the configuration.
    case reconnecting(TunnelConnectionInfo)
}

extension TunnelState: CustomStringConvertible {
    var description: String {
        switch self {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnecting:
            return "disconnecting"
        case .disconnected:
            return "disconnected"
        case .reconnecting:
            return "reconnecting"
        }
    }
}

extension TunnelState: CustomDebugStringConvertible {
    var debugDescription: String {
        var output = "TunnelState."

        switch self {
        case .connecting:
            output.append("connecting")

        case .connected(let connectionInfo):
            output.append("connected(")
            output.append(String(reflecting: connectionInfo))
            output.append(")")

        case .disconnecting:
            output.append("disconnecting")

        case .disconnected:
            output.append("disconnected")

        case .reconnecting(let connectionInfo):
            output.append("reconnecting(")
            output.append(String(reflecting: connectionInfo))
            output.append(")")
        }

        return output
    }
}

protocol TunnelObserver: class {
    func tunnelStateDidChange(tunnelState: TunnelState)
    func tunnelPublicKeyDidChange(publicKey: WireguardPublicKey?)
}

private final class WeakTunnelObserverBox: TunnelObserver {
    private(set) weak var observer: TunnelObserver?

    init<T: TunnelObserver>(observer: T) {
        self.observer = observer
    }

    func tunnelStateDidChange(tunnelState: TunnelState) {
        self.observer?.tunnelStateDidChange(tunnelState: tunnelState)
    }

    func tunnelPublicKeyDidChange(publicKey: WireguardPublicKey?) {
        self.observer?.tunnelPublicKeyDidChange(publicKey: publicKey)
    }
}

/// A class that provides a convenient interface for VPN tunnels configuration, manipulation and
/// monitoring.
class TunnelManager {

    /// An error emitted by all public methods of TunnelManager
    enum Error: ChainedError {
        /// Account token is not set
        case missingAccount

        /// A failure to stop the VPN tunnel via system call
        case startVPNTunnel(Swift.Error)

        /// A failure to load the system VPN configurations created by the app
        case loadAllVPNConfigurations(Swift.Error)

        /// A failure to save the system VPN configuration
        case saveVPNConfiguration(Swift.Error)

        /// A failure to reload the system VPN configuration
        case reloadVPNConfiguration(Swift.Error)

        /// A failure to remove the system VPN configuration
        case removeVPNConfiguration(Swift.Error)

        /// A failure to perform a recovery (by removing the VPN configuration) when the
        /// inconsistency between the given account token and the username saved in the tunnel
        /// provider configuration is detected.
        case removeInconsistentVPNConfiguration(Swift.Error)

        /// A failure to read tunnel configuration
        case readTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to add the tunnel configuration
        case addTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to update the tunnel configuration
        case updateTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to remove the tunnel configuration from Keychain
        case removeTunnelSettings(TunnelSettingsManager.Error)

        /// Unable to obtain the persistent keychain reference for the tunnel configuration
        case obtainPersistentKeychainReference(TunnelSettingsManager.Error)

        /// A failure to push the public WireGuard key
        case pushWireguardKey(MullvadRpc.Error)

        /// A failure to replace the public WireGuard key
        case replaceWireguardKey(MullvadRpc.Error)

        /// A failure to verify the public WireGuard key
        case verifyWireguardKey(MullvadRpc.Error)

        var errorDescription: String? {
            switch self {
            case .missingAccount:
                return "Missing account token"
            case .startVPNTunnel:
                return "Failed to start the VPN tunnel"
            case .loadAllVPNConfigurations:
                return "Failed to load the system VPN configurations"
            case .saveVPNConfiguration:
                return "Failed to save the system VPN configuration"
            case .reloadVPNConfiguration:
                return "Failed to reload the system VPN configuration"
            case .removeVPNConfiguration:
                return "Failed to remove the system VPN configuration"
            case .removeInconsistentVPNConfiguration:
                return "Failed to remove the inconsistent VPN tunnel"
            case .readTunnelSettings:
                return "Failed to read the tunnel settings"
            case .addTunnelSettings:
                return "Failed to add the tunnel settings"
            case .updateTunnelSettings:
                return "Failed to update the tunnel settings"
            case .removeTunnelSettings:
                return "Failed to remove the tunnel settings"
            case .obtainPersistentKeychainReference:
                return "Failed to obtain the persistent keychain refrence"
            case .pushWireguardKey:
                return "Failed to push the WireGuard key to server"
            case .replaceWireguardKey:
                return "Failed to replace the WireGuard key on server"
            case .verifyWireguardKey:
                return "Failed to verify the WireGuard key on server"
            }
        }
    }

    // Switch to stabs on simulator
    #if targetEnvironment(simulator)
    typealias TunnelProviderManagerType = SimulatorTunnelProviderManager
    #else
    typealias TunnelProviderManagerType = NETunnelProviderManager
    #endif

    static let shared = TunnelManager()

    // MARK: - Internal variables

    private let dispatchQueue = DispatchQueue(label: "net.mullvad.MullvadVPN.TunnelManager")

    private let rpc = MullvadRpc.withEphemeralURLSession()
    private var tunnelProvider: TunnelProviderManagerType?
    private var tunnelIpc: PacketTunnelIpc?

    private let stateLock = NSLock()
    private var tunnelObservers = [WeakTunnelObserverBox]()

    /// A VPN connection status observer
    private var connectionStatusObserver: NSObjectProtocol?

    /// An account token associated with the active tunnel
    private var accountToken: String?

    private var _tunnelState = TunnelState.disconnected
    private var _publicKey: WireguardPublicKey?

    private init() {}

    // MARK: - Public

    private(set) var tunnelState: TunnelState {
        set {
            stateLock.withCriticalBlock {
                _tunnelState = newValue

                notifyTunnelObservers { (observer) in
                    observer.tunnelStateDidChange(tunnelState: newValue)
                }
            }
        }
        get {
            stateLock.withCriticalBlock {
                return _tunnelState
            }
        }
    }

    /// The last known public key
    private(set) var publicKey: WireguardPublicKey? {
        set {
            stateLock.withCriticalBlock {
                _publicKey = newValue

                notifyTunnelObservers { (observer) in
                    observer.tunnelPublicKeyDidChange(publicKey: newValue)
                }
            }
        }
        get {
            stateLock.withCriticalBlock {
                return _publicKey
            }
        }
    }

    /// Initialize the TunnelManager with the tunnel from the system
    ///
    /// The given account token is used to ensure that the system tunnel was configured for the same
    /// account. The system tunnel is removed in case of inconsistency.
    func loadTunnel(accountToken: String?, completionHandler: @escaping (Result<(), TunnelManager.Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), TunnelManager.Error>> { (finish) in
            TunnelProviderManagerType.loadAllFromPreferences { (tunnels, error) in
                self.dispatchQueue.async {
                    if let error = error {
                        finish(.failure(.loadAllVPNConfigurations(error)))
                    } else {
                        if let accountToken = self.accountToken {
                            // Migrate the tunnel settings if needed
                            Self.migrateTunnelSettings(accountToken: accountToken)

                            // Load last known public key
                            self.loadPublicKey(accountToken: accountToken)
                        }

                        if let tunnelProvider = tunnels?.first {
                            // Ensure the consistency between the given account token and the one
                            // saved in the system tunnel configuration.
                            if let username = tunnelProvider.protocolConfiguration?.username,
                                let accountToken = accountToken, accountToken == username {
                                self.accountToken = accountToken

                                self.setTunnelProvider(tunnelProvider: tunnelProvider)

                                finish(.success(()))
                            } else {
                                // In case of inconsistency, remove the tunnel
                                tunnelProvider.removeFromPreferences { (error) in
                                    self.dispatchQueue.async {
                                        if let error = error {
                                            finish(.failure(.removeInconsistentVPNConfiguration(error)))
                                        } else {
                                            self.accountToken = accountToken

                                            finish(.success(()))
                                        }
                                    }
                                }
                            }
                        } else {
                            // No tunnels found. Save the account token.
                            self.accountToken = accountToken

                            finish(.success(()))
                        }
                    }
                }
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    /// Refresh tunnel state.
    /// Use this method to update the tunnel state when app transitions from suspended to active
    /// state.
    func refreshTunnelState(completionHandler: (() -> Void)?) {
        let operation = BlockOperation {
            // Reload the last known public key
            if let accountToken = self.accountToken {
                self.loadPublicKey(accountToken: accountToken)
            }

            if let status = self.tunnelProvider?.connection.status {
                self.updateTunnelState(connectionStatus: status)
            }

            completionHandler?()
        }

        addTunnelControlOperation(operation)
    }

    func startTunnel(completionHandler: @escaping (Result<(), Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), Error>> { (finish) in
            guard let accountToken = self.accountToken else {
                finish(.failure(.missingAccount))
                return
            }

            self.makeTunnelProvider(accountToken: accountToken) { (result) in
                let result = result.flatMap { (tunnelProvider) -> Result<(), Error> in
                    self.setTunnelProvider(tunnelProvider: tunnelProvider)
                    return Result { try tunnelProvider.connection.startVPNTunnel() }
                        .mapError { Error.startVPNTunnel($0) }
                }
                finish(result)
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    func stopTunnel(completionHandler: @escaping (Result<(), Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), Error>> { (finish) in
            guard let tunnelProvider = self.tunnelProvider else {
                completionHandler(.success(()))
                return
            }

            // Disable on-demand when stopping the tunnel to prevent it from coming back up
            tunnelProvider.isOnDemandEnabled = false

            tunnelProvider.saveToPreferences { (error) in
                if let error = error {
                    finish(.failure(.saveVPNConfiguration(error)))
                } else {
                    tunnelProvider.connection.stopVPNTunnel()
                    finish(.success(()))
                }
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    func setAccount(accountToken: String, completionHandler: @escaping (Result<(), TunnelManager.Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), TunnelManager.Error>> { (finish) in
            let result = Self.makeTunnelSettings(accountToken: accountToken)

            guard case .success(let tunnelSettings) = result else {
                finish(result.map { _ in () })
                return
            }

            let interfaceSettings = tunnelSettings.interface
            let publicKey = interfaceSettings.privateKey.publicKey

            let saveAccountData = {
                // Save the last known public key
                self.publicKey = publicKey
                self.accountToken = accountToken
            }

            guard interfaceSettings.addresses.isEmpty else {
                saveAccountData()
                finish(.success(()))
                return
            }

            // Push wireguard key if addresses were not received yet
            self.pushWireguardKeyAndUpdateSettings(accountToken: accountToken, publicKey: publicKey) { (result) in
                if case .success = result {
                    saveAccountData()
                }
                finish(result)
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    /// Remove the account token and remove the active tunnel
    func unsetAccount(completionHandler: @escaping (Result<(), TunnelManager.Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), TunnelManager.Error>> { (finish) in
            guard let accountToken = self.accountToken else {
                finish(.failure(.missingAccount))
                return
            }

            let cleanupState = {
                self.accountToken = nil
                self.publicKey = nil
                self.tunnelProvider = nil
                self.tunnelIpc = nil

                self.unregisterConnectionObserver()
                self.tunnelState = .disconnected
            }

            let removeFromKeychainAndServer = {
                switch Self.loadTunnelSettings(accountToken: accountToken) {
                case .success(let keychainEntry):
                    let publicKey = keychainEntry.tunnelSettings
                        .interface
                        .privateKey
                        .publicKey
                        .rawRepresentation

                    // Remove WireGuard key from server
                    let rpcRequest = self.rpc.removeWireguardKey(
                        accountToken: keychainEntry.accountToken,
                        publicKey: publicKey
                    )

                    let urlSessionTask = rpcRequest.dataTask(completionHandler: { (result) in
                        self.dispatchQueue.async {
                            switch result {
                            case .success(let isRemoved):
                                os_log(.debug, "Removed the WireGuard key from server: %{public}s", "\(isRemoved)")

                            case .failure(let error):
                                os_log(.error, "%{public}s", error.displayChain(message: "Failed to unset account"))
                            }

                            cleanupState()
                            finish(.success(()))
                        }
                    })

                    urlSessionTask?.resume()

                case .failure(let error):
                    // Ignore Keychain errors because that normally means that the Keychain
                    // configuration was already removed and we shouldn't be blocking the
                    // user from logging out
                    os_log(.error, "%{public}s", error.displayChain(message: "Failed to unset account"))

                    cleanupState()
                    finish(.success(()))
                }
            }

            guard let tunnelProvider = self.tunnelProvider else {
                removeFromKeychainAndServer()
                return
            }

            // Remove VPN configuration
            tunnelProvider.removeFromPreferences(completionHandler: { (error) in
                self.dispatchQueue.async {
                    if let error = error {
                        // Ignore error if the tunnel was already removed by user
                        if let systemError = error as? NEVPNError, systemError.code == .configurationInvalid {
                            removeFromKeychainAndServer()
                        } else {
                            finish(.failure(.removeVPNConfiguration(error)))
                        }
                    } else {
                        removeFromKeychainAndServer()
                    }
                }
            })
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    func verifyPublicKey(completionHandler: @escaping (Result<Bool, Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<Bool, Error>> { (finish) in
            guard let accountToken = self.accountToken else {
                finish(.failure(.missingAccount))
                return
            }

            switch Self.loadTunnelSettings(accountToken: accountToken) {
            case .success(let keychainEntry):
                let publicKey = keychainEntry.tunnelSettings.interface
                    .privateKey
                    .publicKey.rawRepresentation

                let rpcRequest = self.rpc.checkWireguardKey(
                    accountToken: keychainEntry.accountToken,
                    publicKey: publicKey
                )

                let urlSessionTask = rpcRequest.dataTask { (result) in
                    finish(result.mapError { Error.verifyWireguardKey($0) })
                }

                urlSessionTask?.resume()

            case .failure(let error):
                finish(.failure(error))
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        operationQueue.addOperation(operation)
    }

    func regeneratePrivateKey(completionHandler: @escaping (Result<(), Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), Error>> { (finish) in
            guard let accountToken = self.accountToken else {
                finish(.failure(.missingAccount))
                return
            }

            let result = Self.loadTunnelSettings(accountToken: accountToken)
            guard case .success(let keychainEntry) = result else {
                finish(result.map { _ in () })
                return
            }

            let newPrivateKey = WireguardPrivateKey()
            let oldPublicKey = keychainEntry.tunnelSettings.interface
                .privateKey
                .publicKey

            self.replaceWireguardKeyAndUpdateSettings(accountToken: accountToken, oldPublicKey: oldPublicKey, newPrivateKey: newPrivateKey) { (result) in
                guard case .success = result else {
                    finish(result)
                    return
                }

                // Save new public key
                self.publicKey = newPrivateKey.publicKey

                guard let tunnelIpc = self.tunnelIpc else {
                    finish(.success(()))
                    return
                }

                tunnelIpc.reloadTunnelSettings { (ipcResult) in
                    if case .failure(let error) = ipcResult {
                        // Ignore Packet Tunnel IPC errors but log them
                        os_log(.error, "%{public}s", error.displayChain(message: "Failed to IPC the tunnel to reload configuration"))
                    }

                    finish(.success(()))
                }
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    func setRelayConstraints(_ constraints: RelayConstraints, completionHandler: @escaping (Result<(), TunnelManager.Error>) -> Void) {
        let operation = AsyncBlockOutputOperation<Result<(), TunnelManager.Error>> { (finish) in
            guard let accountToken = self.accountToken else {
                finish(.failure(.missingAccount))
                return
            }

            let result = Self.updateTunnelSettings(accountToken: accountToken) { (tunnelSettings) in
                tunnelSettings.relayConstraints = constraints
            }
            
            guard case .success = result else {
                finish(result.map { _ in () })
                return
            }

            guard let tunnelIpc = self.tunnelIpc else {
                finish(.success(()))
                return
            }

            tunnelIpc.reloadTunnelSettings { (ipcResult) in
                // Ignore Packet Tunnel IPC errors but log them
                if case .failure(let error) = ipcResult {
                    os_log(.error, "%{public}s", error.displayChain(message: "Failed to reload tunnel settings"))
                }

                finish(.success(()))
            }
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addTunnelControlOperation(operation)
    }

    func getRelayConstraints(completionHandler: @escaping (Result<RelayConstraints, TunnelManager.Error>) -> Void) {
        let operation = BlockOperation {
            guard let accountToken = self.accountToken else {
                completionHandler(.failure(.missingAccount))
                return
            }

            let result = Self.loadTunnelSettings(accountToken: accountToken)
                .map { (keychainEntry) -> RelayConstraints in
                    return keychainEntry.tunnelSettings.relayConstraints
            }

            completionHandler(result)
        }

        addTunnelControlOperation(operation)
    }

    // MARK: - Tunnel observeration

    /// Add tunnel observer.
    /// In order to cancel the observation, either call `removeTunnelObserver(_:)` or simply release
    /// the observer.
    public func addTunnelObserver<T: TunnelObserver>(_ observer: T) {
        dispatchQueue.async {
            let boxed = WeakTunnelObserverBox(observer: observer)

            self.tunnelObservers.append(boxed)
        }
    }

    /// Remove tunnel observer.
    public func removeTunnelObserver(_ observer: TunnelObserver) {
        dispatchQueue.async {
            self.tunnelObservers.removeAll { (box) -> Bool in
                return box.observer === observer
            }
        }
    }

    /// Private helper that loops through the registered observers and calls the given closure
    /// for each of them. Additionally this method takes care of discarding released observers.
    private func notifyTunnelObservers(block: @escaping (TunnelObserver) -> Void) {
        dispatchQueue.async {
            var discardIndices = [Int]()

            self.tunnelObservers.enumerated().forEach { (index, anyObserver) in
                if anyObserver.observer == nil {
                    discardIndices.append(index)
                } else {
                    block(anyObserver)
                }
            }

            discardIndices.reversed().forEach { (index) in
                self.tunnelObservers.remove(at: index)
            }
        }
    }

    // MARK: - Operation management

    private lazy var operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.underlyingQueue = self.dispatchQueue
        return queue
    }()
    private var tunnelControlOperation: Operation?
    private var tunnelStateUpdateOperation: Operation?

    private func addTunnelControlOperation(_ operation: Operation) {
        dispatchQueue.async {
            if let dependency = self.tunnelControlOperation {
                operation.addDependency(dependency)
            }
            self.tunnelControlOperation = operation
            self.operationQueue.addOperation(operation)
        }
    }

    private func addTunnelStateUpdateOperation(_ operation: Operation) {
        dispatchQueue.async {
            if let dependency = self.tunnelStateUpdateOperation {
                operation.addDependency(dependency)
            }
            self.tunnelStateUpdateOperation = operation
            self.operationQueue.addOperation(operation)
        }
    }

    // MARK: - Private methods

    /// Set the instance of the active tunnel and add the tunnel status observer
    private func setTunnelProvider(tunnelProvider: TunnelProviderManagerType) {
        guard self.tunnelProvider != tunnelProvider else {
            return
        }

        // Save the new active tunnel provider
        self.tunnelProvider = tunnelProvider

        // Set up tunnel IPC
        let connection = tunnelProvider.connection
        let session = connection as! VPNTunnelProviderSessionProtocol
        let tunnelIpc = PacketTunnelIpc(session: session)
        self.tunnelIpc = tunnelIpc

        // Register for tunnel connection status changes
        unregisterConnectionObserver()
        connectionStatusObserver = NotificationCenter.default
            .addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: operationQueue) {
                [weak self] (notification) in
                guard let self = self else { return }

                let connection = notification.object as? VPNConnectionProtocol

                if let status = connection?.status {
                    self.updateTunnelState(connectionStatus: status)
                }
        }

        // Update the existing state
        updateTunnelState(connectionStatus: tunnelProvider.connection.status)
    }

    private func unregisterConnectionObserver() {
        if let connectionStatusObserver = connectionStatusObserver {
            NotificationCenter.default.removeObserver(connectionStatusObserver)
            self.connectionStatusObserver = nil
        }
    }

    private func loadPublicKey(accountToken: String) {
        switch TunnelSettingsManager.load(searchTerm: .accountToken(accountToken)) {
        case .success(let entry):
            self.publicKey = entry.tunnelSettings.interface.privateKey.publicKey

        case .failure(let error):
            os_log(.error, "%{public}s", error.displayChain(message: "Failed to load the public key"))

            self.publicKey = nil
        }
    }

    private func pushWireguardKeyAndUpdateSettings(
        accountToken: String,
        publicKey: WireguardPublicKey,
        completionHandler: @escaping (Result<(), Error>) -> Void)
    {
        let rpcRequest = self.rpc.pushWireguardKey(
            accountToken: accountToken,
            publicKey: publicKey.rawRepresentation
        )

        let urlSessionTask = rpcRequest.dataTask { (rpcResult) in
            self.dispatchQueue.async {
                let updateResult = rpcResult
                    .mapError({ (rpcError) -> Error in
                        return Error.pushWireguardKey(rpcError)
                    })
                    .flatMap { (associatedAddresses) -> Result<(), Error> in
                        return Self.updateTunnelSettings(accountToken: accountToken) { (tunnelSettings) in
                            tunnelSettings.interface.addresses = [
                                associatedAddresses.ipv4Address,
                                associatedAddresses.ipv6Address
                            ]
                        }.map { _ in () }
                }

                completionHandler(updateResult)
            }
        }

        urlSessionTask?.resume()
    }

    private func replaceWireguardKeyAndUpdateSettings(
        accountToken: String,
        oldPublicKey: WireguardPublicKey,
        newPrivateKey: WireguardPrivateKey,
        completionHandler: @escaping (Result<(), Error>) -> Void)
    {
        let rpcRequest = self.rpc.replaceWireguardKey(
            accountToken: accountToken,
            oldPublicKey: oldPublicKey.rawRepresentation,
            newPublicKey: newPrivateKey.publicKey.rawRepresentation
        )

        let urlSessionTask = rpcRequest.dataTask { (rpcResult) in
            self.dispatchQueue.async {
                let updateResult = rpcResult
                    .mapError({ (rpcError) -> Error in
                        return Error.replaceWireguardKey(rpcError)
                    })
                    .flatMap { (associatedAddresses) -> Result<(), Error> in
                        return Self.updateTunnelSettings(accountToken: accountToken) { (tunnelSettings) in
                            tunnelSettings.interface.privateKey = newPrivateKey
                            tunnelSettings.interface.addresses = [
                                associatedAddresses.ipv4Address,
                                associatedAddresses.ipv6Address
                            ]
                        }.map { _ in () }
                }

                completionHandler(updateResult)
            }
        }

        urlSessionTask?.resume()
    }

    /// Initiates the `tunnelState` update
    private func updateTunnelState(connectionStatus: NEVPNStatus) {
        let operation = AsyncBlockOperation { (finish) in
            self.mapTunnelState(connectionStatus: connectionStatus) { (result) in
                switch result {
                case .success(let tunnelState):
                    os_log(.default, "Set tunnel state: %{public}s", "\(tunnelState)")
                    self.tunnelState = tunnelState

                case .failure(let error):
                    os_log(.error, "%{public}s",
                           error.displayChain(message: "Failed to map the tunnel state"))
                }

                finish()
            }
        }

        addTunnelStateUpdateOperation(operation)
    }

    /// Maps `NEVPNStatus` to `TunnelState`.
    /// Collects the `TunnelConnectionInfo` from the tunnel via IPC if needed before assigning the
    /// `tunnelState`
    private func mapTunnelState(connectionStatus: NEVPNStatus, completionHandler: @escaping (Result<TunnelState, MapConnectionStatusError>) -> Void) {
        switch connectionStatus {
        case .connected:
            guard let tunnelIpc = tunnelIpc else {
                completionHandler(.failure(.missingIpc))
                return
            }

            tunnelIpc.getTunnelInformation { (result) in
                self.dispatchQueue.async {
                    let result = result.map { TunnelState.connected($0) }
                        .mapError { MapConnectionStatusError.ipcRequest($0) }

                    completionHandler(result)
                }
            }

        case .connecting:
            completionHandler(.success(.connecting))

        case .disconnected:
            completionHandler(.success(.disconnected))

        case .disconnecting:
            completionHandler(.success(.disconnecting))

        case .reasserting:
            // Refresh the last known public key on reconnect to cover the possibility of
            // the key being changed due to key rotation.
            if let accountToken = self.accountToken {
                self.loadPublicKey(accountToken: accountToken)
            }

            guard let tunnelIpc = tunnelIpc else {
                completionHandler(.failure(.missingIpc))
                return
            }

            tunnelIpc.getTunnelInformation { (result) in
                self.dispatchQueue.async {
                    let result = result.map { TunnelState.reconnecting($0) }
                        .mapError { MapConnectionStatusError.ipcRequest($0) }

                    completionHandler(result)
                }
            }

        case .invalid:
            completionHandler(.failure(.invalidConfiguration))

        @unknown default:
            completionHandler(.failure(.unknownStatus(connectionStatus)))
        }
    }

    private func makeTunnelProvider(accountToken: String, completionHandler: @escaping (Result<TunnelProviderManagerType, TunnelManager.Error>) -> Void) {
        TunnelProviderManagerType.loadAllFromPreferences { (tunnels, error) in
            self.dispatchQueue.async {
                if let error = error {
                    completionHandler(.failure(.loadAllVPNConfigurations(error)))
                } else {
                    let result = Self.setupTunnelProvider(accountToken: accountToken, tunnels: tunnels)

                    guard case .success(let tunnelProvider) = result else {
                        completionHandler(result)
                        return
                    }

                    tunnelProvider.saveToPreferences { (error) in
                        self.dispatchQueue.async {
                            if let error = error {
                                completionHandler(.failure(.saveVPNConfiguration(error)))
                            } else {
                                // Refresh connection status after saving the tunnel preferences.
                                // Basically it's only necessary to do for new instances of
                                // `NETunnelProviderManager`, but we do that for the existing ones too
                                // for simplicity as it has no side effects.
                                tunnelProvider.loadFromPreferences { (error) in
                                    self.dispatchQueue.async {
                                        if let error = error {
                                            completionHandler(.failure(.reloadVPNConfiguration(error)))
                                        } else {
                                            completionHandler(.success(tunnelProvider))
                                        }
                                    }
                                }
                            }
                        }
                    }

                }
            }
        }
    }

    // MARK: - Private class methods

    private class func loadTunnelSettings(accountToken: String) -> Result<TunnelSettingsManager.KeychainEntry, Error> {
        return TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
            .mapError { Error.readTunnelSettings($0) }
    }

    private class func updateTunnelSettings(accountToken: String, block: (inout TunnelSettings) -> Void) -> Result<TunnelSettings, Error> {
        return TunnelSettingsManager.update(searchTerm: .accountToken(accountToken), using: block)
            .mapError { Error.updateTunnelSettings($0) }
    }

    /// Retrieve the existing `TunnelSettings` or create the new ones
    private class func makeTunnelSettings(accountToken: String) -> Result<TunnelSettings, TunnelManager.Error> {
        return TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
            .map { $0.tunnelSettings }
            .flatMapError { (error) -> Result<TunnelSettings, TunnelManager.Error> in
                // Return default tunnel configuration if the config is not found in Keychain
                if case .lookupEntry(.itemNotFound) = error {
                    let defaultConfiguration = TunnelSettings()

                    return TunnelSettingsManager
                        .add(configuration: defaultConfiguration, account: accountToken)
                        .mapError { .addTunnelSettings($0) }
                        .map { defaultConfiguration }
                } else {
                    return .failure(.readTunnelSettings(error))
                }
        }
    }

    private class func setupTunnelProvider(accountToken: String ,tunnels: [TunnelProviderManagerType]?) -> Result<TunnelProviderManagerType, Error> {
        // Request persistent keychain reference to tunnel settings
        return TunnelSettingsManager.getPersistentKeychainReference(account: accountToken)
            .map { (passwordReference) -> TunnelProviderManagerType in
                // Get the first available tunnel or make a new one
                let tunnelProvider = tunnels?.first ?? TunnelProviderManagerType()

                let protocolConfig = NETunnelProviderProtocol()
                protocolConfig.providerBundleIdentifier = ApplicationConfiguration.packetTunnelExtensionIdentifier
                protocolConfig.serverAddress = ""
                protocolConfig.username = accountToken
                protocolConfig.passwordReference = passwordReference

                tunnelProvider.isEnabled = true
                tunnelProvider.localizedDescription = "WireGuard"
                tunnelProvider.protocolConfiguration = protocolConfig

                // Enable on-demand VPN, always connect the tunnel when on Wi-Fi or cellular
                let alwaysOnRule = NEOnDemandRuleConnect()
                alwaysOnRule.interfaceTypeMatch = .any
                tunnelProvider.onDemandRules = [alwaysOnRule]
                tunnelProvider.isOnDemandEnabled = true

                return tunnelProvider
        }.mapError { (error) -> Error in
            return .obtainPersistentKeychainReference(error)
        }
    }

    private class func migrateTunnelSettings(accountToken: String) {
        let result = TunnelSettingsManager
            .migrateKeychainEntry(searchTerm: .accountToken(accountToken))

        switch result {
        case .success(let migrated):
            if migrated {
                os_log("Migrated Keychain tunnel configuration")
            } else {
                os_log("Tunnel settings are up to date. No migration needed.")
            }

        case .failure(let error):
            os_log("%{public}s", error.displayChain(message: "Failed to migrate tunnel settings"))
        }
    }

}
