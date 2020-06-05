//
//  TunnelManager.swift
//  MullvadVPN
//
//  Created by pronebird on 25/09/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Combine
import Foundation
import NetworkExtension
import os

enum TunnelIpcRequestError: ChainedError {
    /// IPC is not set yet
    case missingIpc

    /// A failure to submit or handle the IPC request
    case send(PacketTunnelIpc.Error)

    var errorDescription: String? {
        switch self {
        case .missingIpc:
            return "IPC is not initialized yet"

        case .send:
            return "Failure to send an IPC request"
        }
    }
}

enum MapConnectionStatusError: ChainedError {
    /// A failure to send a subsequent IPC request to collect more information, such as tunnel
    /// connection info.
    case ipcRequest(TunnelIpcRequestError)

    /// A failure to map the status because the unknown variant of `NEVPNStatus` was given.
    case unknownStatus(NEVPNStatus)

    /// A failure to map the status because the `NEVPNStatus.invalid` variant was given
    /// This happens when attempting to start a tunnel with configuration that does not exist
    /// anymore in system preferences.
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
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

/// A class that provides a convenient interface for VPN tunnels configuration, manipulation and
/// monitoring.
class TunnelManager {

    /// An error emitted by all public methods of TunnelManager
    enum Error: ChainedError {
        /// Account token is not set
        case missingAccount

        /// A failure to stop the VPN tunnel via system call
        case startVPNTunnel(Swift.Error)

        /// A failure to start the VPN tunnel via system call
        case stopVPNTunnel(Swift.Error)

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

        var errorDescription: String? {
            switch self {
            case .missingAccount:
                return "Missing account token"
            case .startVPNTunnel:
                return "Failed to start the VPN tunnel"
            case .stopVPNTunnel:
                return "Failed to stop the VPN tunnel"
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

    /// A queue used for dispatching tunnel related jobs that require mutual exclusion
    private let exclusivityQueue = DispatchQueue(label: "net.mullvad.vpn.tunnel-manager.exclusivity-queue")

    /// A queue used for access synchronization to the TunnelManager members
    private let executionQueue = DispatchQueue(label: "net.mullvad.vpn.tunnel-manager.execution-queue")

    private let rpc = MullvadRpc.withEphemeralURLSession()
    private var tunnelProvider: TunnelProviderManagerType?
    private var tunnelIpc: PacketTunnelIpc?

    /// A subscriber used for tunnel connection status changes
    private var tunnelStatusSubscriber: AnyCancellable?

    /// A subscriber used for mapping a connection status (`NEVPNStatus`) to `TunnelState`
    private var mapTunnelStateSubscriber: AnyCancellable?

    /// An account token associated with the active tunnel
    private var accountToken: String?

    private init() {}

    // MARK: - Public

    @Published private(set) var tunnelState = TunnelState.disconnected

    /// A last known public key
    @Published private(set) var publicKey: WireguardPublicKey?

    /// Initialize the TunnelManager with the tunnel from the system
    ///
    /// The given account token is used to ensure that the system tunnel was configured for the same
    /// account. The system tunnel is removed in case of inconsistency.
    func loadTunnel(accountToken: String?) -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            TunnelProviderManagerType.loadAllFromPreferences()
                .mapError { TunnelManager.Error.loadAllVPNConfigurations($0) }
                .receive(on: self.executionQueue)
                .flatMap { (tunnels) -> AnyPublisher<(), TunnelManager.Error> in

                    if let accountToken = accountToken {
                        // Migrate tunnel configuration if needed
                        self.migrateTunnelConfiguration(accountToken: accountToken)

                        // Load last known public key
                        self.loadPublicKey(accountToken: accountToken)
                    }

                    // No tunnels found. Save the account token.
                    guard let tunnelProvider = tunnels?.first else {
                        self.accountToken = accountToken

                        return Result.Publisher(()).eraseToAnyPublisher()
                    }

                    // Ensure the consistency between the given account token and the one
                    // saved in the system tunnel configuration.
                    if let username = tunnelProvider.protocolConfiguration?.username,
                        let accountToken = accountToken, accountToken == username {
                        self.accountToken = accountToken
                        self.setTunnelProvider(tunnelProvider: tunnelProvider)

                        return Result.Publisher(()).eraseToAnyPublisher()
                    } else {
                        // In case of inconsistency, remove the tunnel
                        return tunnelProvider.removeFromPreferences()
                            .receive(on: self.executionQueue)
                            .mapError { TunnelManager.Error.removeInconsistentVPNConfiguration($0) }
                            .handleEvents(receiveCompletion: { completion in
                                if case .finished = completion {
                                    self.accountToken = accountToken
                                }
                            }).eraseToAnyPublisher()
                    }
            }
        }.eraseToAnyPublisher()
    }

    /// Refresh tunnel state.
    /// Use this method to update the tunnel state when app transitions from suspended to active
    /// state.
    func refreshTunnelState() -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            () -> AnyPublisher<(), TunnelManager.Error> in
            if let status = self.tunnelProvider?.connection.status {
                self.updateTunnelState(connectionStatus: status)
            }

            // Reload the last known public key
            if let accountToken = self.accountToken {
                self.loadPublicKey(accountToken: accountToken)
            }
            return Result.Publisher(()).eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    func startTunnel() -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            Just(self.accountToken)
                .setFailureType(to: TunnelManager.Error.self)
                .replaceNil(with: .missingAccount)
                .flatMap { (accountToken) -> AnyPublisher<(), TunnelManager.Error> in
                    self.pushWireguardKeyIfNeeded(accountToken: accountToken)
                        .flatMap { () -> AnyPublisher<(), TunnelManager.Error> in
                            self.setupTunnel(accountToken: accountToken)
                                .flatMap({ (tunnelProvider) -> Result<(), TunnelManager.Error>.Publisher in
                                    Just(tunnelProvider)
                                        .tryMap { try $0.connection.startVPNTunnel() }
                                        .mapError { TunnelManager.Error.startVPNTunnel($0) }
                                }).eraseToAnyPublisher()
                    }.eraseToAnyPublisher()
            }
        }.eraseToAnyPublisher()
    }

    func stopTunnel() -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) { () -> AnyPublisher<(), TunnelManager.Error> in
            if let tunnelProvider = self.tunnelProvider {
                // Disable on-demand when turning off the tunnel to prevent the tunnel from coming
                // back up
                tunnelProvider.isOnDemandEnabled = false

                return tunnelProvider.saveToPreferences()
                    .mapError { TunnelManager.Error.stopVPNTunnel($0) }
                    .map { _ -> () in
                        tunnelProvider.connection.stopVPNTunnel()
                        return ()
                }.eraseToAnyPublisher()
            } else {
                return Result.Publisher(()).eraseToAnyPublisher()
            }
        }.eraseToAnyPublisher()
    }

    func setAccount(accountToken: String) -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            self.makeTunnelConfiguration(accountToken: accountToken)
                .map { (tunnelConfig: TunnelSettings) in
                    let publicKey = tunnelConfig.interface.privateKey.publicKey

                    // Save the last known public key
                    self.publicKey = publicKey
                    self.accountToken = accountToken

                    return ()
            }.publisher
        }.eraseToAnyPublisher()
    }

    /// Remove the account token and remove the active tunnel
    func unsetAccount() -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            Just(self.accountToken)
                .setFailureType(to: TunnelManager.Error.self)
                .replaceNil(with: .missingAccount)
                .map { ($0, self.tunnelProvider) }
                .flatMap { (accountToken, tunnelProvider) -> AnyPublisher<(), TunnelManager.Error> in

                    let removeKeychainConfigPublisher = Deferred {
                        () -> AnyPublisher<(), TunnelManager.Error> in
                        // Load existing configuration
                        switch TunnelSettingsManager.load(searchTerm: .accountToken(accountToken)) {
                        case .success(let keychainEntry):
                            let publicKey = keychainEntry.tunnelConfiguration
                                .interface
                                .privateKey
                                .publicKey
                                .rawRepresentation

                            // Remove configuration from Keychain
                            return TunnelSettingsManager.remove(searchTerm: .accountToken(accountToken))
                                .mapError { TunnelManager.Error.removeTunnelSettings($0) }
                                .publisher
                                .flatMap {
                                    // Remove WireGuard key from master
                                    self.rpc.removeWireguardKey(
                                        accountToken: accountToken,
                                        publicKey: publicKey
                                    ).publisher
                                        .retry(1)
                                        .map({ (isRemoved) -> () in
                                            os_log(.debug, "Removed the WireGuard key from server: %{public}s", "\(isRemoved)")
                                            return ()
                                        }).catch({ (error) -> Result<(), TunnelManager.Error>.Publisher in
                                            os_log(.error, "Failed to remove the Wireguard key from server: %{public}s", error.localizedDescription)

                                            // Suppress network errors
                                            return Result.Publisher(())
                                        })
                            }.eraseToAnyPublisher()

                        case .failure(let error):
                            // Ignore Keychain errors because that normally means that the Keychain
                            // configuration was already removed and we shouldn't be blocking the
                            // user from logging out
                            os_log(.error, "Failed to read the tunnel configuration from Keychain: %{public}s", error.localizedDescription)

                            return Just(())
                                .setFailureType(to: TunnelManager.Error.self)
                                .eraseToAnyPublisher()
                        }
                    }

                    let removeTunnelPublisher = Deferred {
                        () -> AnyPublisher<(), TunnelManager.Error> in
                        if let tunnelProvider = tunnelProvider {
                            return tunnelProvider.removeFromPreferences()
                                .catch { (error) -> Result<(), TunnelManager.Error>.Publisher in
                                    // Ignore error if the tunnel was already removed by user
                                    if case NEVPNError.configurationInvalid = error {
                                        return .init(())
                                    } else {
                                        return .init(.failure(.removeVPNConfiguration(error)))
                                    }
                            }.eraseToAnyPublisher()
                        } else {
                            return Result.Publisher(())
                                .eraseToAnyPublisher()
                        }
                    }

                    return removeTunnelPublisher
                        .receive(on: self.executionQueue)
                        .flatMap { removeKeychainConfigPublisher }
                        .eraseToAnyPublisher()
            }
            .receive(on: self.executionQueue)
            .handleEvents(receiveCompletion: { (completion) in
                if case .finished = completion {
                    self.accountToken = nil
                    self.publicKey = nil
                    self.tunnelProvider = nil
                    self.tunnelIpc = nil

                    self.tunnelStatusSubscriber?.cancel()
                    self.tunnelStatusSubscriber = nil

                    self.mapTunnelStateSubscriber?.cancel()
                    self.mapTunnelStateSubscriber = nil

                    self.tunnelState = .disconnected
                }
            })
        }.eraseToAnyPublisher()
    }

    func regeneratePrivateKey() -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            Just(self.accountToken)
                .setFailureType(to: TunnelManager.Error.self)
                .replaceNil(with: .missingAccount)
                .flatMap { (accountToken) -> AnyPublisher<(), TunnelManager.Error> in
                    let newPrivateKey = WireguardPrivateKey()

                    return TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
                        .map { $0.tunnelConfiguration.interface.privateKey.publicKey }
                        .mapError { TunnelManager.Error.readTunnelSettings($0) }
                        .publisher
                        .flatMap { (oldPublicKey) in
                            self.rpc.replaceWireguardKey(
                                accountToken: accountToken,
                                oldPublicKey: oldPublicKey.rawRepresentation,
                                newPublicKey: newPrivateKey.publicKey.rawRepresentation)
                                .publisher
                                .mapError { TunnelManager.Error.replaceWireguardKey($0) }
                                .receive(on: self.executionQueue)
                                .flatMap { (addresses) in
                                    TunnelSettingsManager.update(searchTerm: .accountToken(accountToken)) {
                                        (tunnelConfiguration) in
                                        tunnelConfiguration.interface.privateKey = newPrivateKey
                                        tunnelConfiguration.interface.addresses = [
                                            addresses.ipv4Address,
                                            addresses.ipv6Address
                                        ]
                                    }
                                    .mapError { .updateTunnelSettings($0) }
                                    .map { _ in () }
                                    .publisher
                            }.receive(on: self.executionQueue)
                                .flatMap { _ -> AnyPublisher<(), TunnelManager.Error> in
                                    // Save new public key
                                    self.publicKey = newPrivateKey.publicKey

                                    // Ignore Packet Tunnel IPC errors but log them
                                    return self.reloadPacketTunnelConfiguration()
                                        .handleEvents(receiveCompletion: { (completion) in
                                            if case .failure(let error) = completion {
                                                os_log(.error, "Failed to tell the tunnel to reload configuration: %{public}s", error.localizedDescription)
                                            }
                                        })
                                        .replaceError(with: ())
                                        .setFailureType(to: TunnelManager.Error.self)
                                        .eraseToAnyPublisher()
                            }
                    }
                    .eraseToAnyPublisher()
            }
        }.eraseToAnyPublisher()
    }

    func setRelayConstraints(_ constraints: RelayConstraints) -> AnyPublisher<(), TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            Just(self.accountToken)
                .setFailureType(to: TunnelManager.Error.self)
                .replaceNil(with: .missingAccount)
                .flatMap { (accountToken) in
                    TunnelSettingsManager
                        .update(searchTerm: .accountToken(accountToken)) { (tunnelConfig) in
                            tunnelConfig.relayConstraints = constraints
                    }.mapError { TunnelManager.Error.updateTunnelSettings($0) }
                        .publisher
                        .flatMap { _ in
                            // Ignore Packet Tunnel IPC errors but log them
                            self.reloadPacketTunnelConfiguration()
                                .replaceError(with: ())
                                .setFailureType(to: TunnelManager.Error.self)
                                .handleEvents(receiveCompletion: { (completion) in
                                    if case .failure(let error) = completion {
                                        os_log(.error, "Failed to tell the tunnel to reload configuration: %{public}s", error.localizedDescription)
                                    }
                                })
                    }
            }
        }.eraseToAnyPublisher()
    }

    func getRelayConstraints() -> AnyPublisher<RelayConstraints, TunnelManager.Error> {
        MutuallyExclusive(exclusivityQueue: exclusivityQueue, executionQueue: executionQueue) {
            Just(self.accountToken)
                .setFailureType(to: TunnelManager.Error.self)
                .replaceNil(with: .missingAccount)
                .flatMap { (accountToken) in
                    TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
                        .map { $0.tunnelConfiguration.relayConstraints }
                        .flatMapError { (error) -> Result<RelayConstraints, TunnelManager.Error> in
                            // Return default constraints if the config is not found in Keychain
                            if case .lookupEntry(.itemNotFound) = error {
                                return .success(TunnelSettings().relayConstraints)
                            } else {
                                return .failure(.readTunnelSettings(error))
                            }
                    }.publisher
            }
        }.eraseToAnyPublisher()
    }

    // MARK: - Private

    /// Tell Packet Tunnel process to reload the tunnel configuration
    private func reloadPacketTunnelConfiguration() -> AnyPublisher<(), TunnelIpcRequestError> {
        return executeIpcRequest { Future($0.reloadTunnelSettings) }
    }

    /// Ask Packet Tunnel process to return the current tunnel connection info
    private func getTunnelConnectionInfo() -> AnyPublisher<TunnelConnectionInfo, TunnelIpcRequestError> {
        return executeIpcRequest { Future($0.getTunnelInformation) }
    }

    /// IPC interactor helper that automatically maps the `PacketTunnelIpcError` to
    /// `TunnelIpcRequestError`
    private func executeIpcRequest<T>(
        _ body: @escaping (PacketTunnelIpc) -> Future<T, PacketTunnelIpc.Error>
    ) -> AnyPublisher<T, TunnelIpcRequestError>
    {
        Just(tunnelIpc)
            .setFailureType(to: TunnelIpcRequestError.self)
            .replaceNil(with: .missingIpc)
            .flatMap { (tunnelIpc) in
                body(tunnelIpc)
                    .mapError { .send($0) }
        }.eraseToAnyPublisher()
    }

    /// Set the instance of the active tunnel and add the tunnel status observer
    private func setTunnelProvider(tunnelProvider: TunnelProviderManagerType) {
        guard self.tunnelProvider != tunnelProvider else { return }

        let connection = tunnelProvider.connection

        // Save the new active tunnel provider
        self.tunnelProvider = tunnelProvider

        // Set up tunnel IPC
        if let session = connection as? VPNTunnelProviderSessionProtocol {
            self.tunnelIpc = PacketTunnelIpc(session: session)
        }

        // Register for tunnel connection status changes
        tunnelStatusSubscriber = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange, object: connection)
            .map { notification in
                (notification.object as? VPNConnectionProtocol)?.status
        }
        .receive(on: executionQueue)
        .sink { [weak self] (connectionStatus) in
            guard let connectionStatus = connectionStatus else { return }

            self?.updateTunnelState(connectionStatus: connectionStatus)
        }

        // Update the existing connection status
        updateTunnelState(connectionStatus: connection.status)
    }

    private func loadPublicKey(accountToken: String) {
        switch TunnelSettingsManager.load(searchTerm: .accountToken(accountToken)) {
        case .success(let entry):
            self.publicKey = entry.tunnelConfiguration.interface.privateKey.publicKey

        case .failure(let error):
            os_log(.error, "Failed to load the public key: %{public}s", error.localizedDescription)

            self.publicKey = nil
        }
    }

    /// Initiates the `tunnelState` update
    private func updateTunnelState(connectionStatus: NEVPNStatus) {
        os_log(.default, "VPN Status: %{public}s", "\(connectionStatus)")

        mapTunnelStateSubscriber = mapTunnelState(connectionStatus: connectionStatus)
            .receive(on: executionQueue)
            .sink(receiveCompletion: { (completion) in
                if case .failure(let error) = completion {
                    os_log(.error, "%{public}s",
                           error.displayChain(message: "Failed to map the tunnel state"))
                }
            }, receiveValue: { (tunnelState) in
                os_log(.default, "Set tunnel state: %{public}s", "\(tunnelState)")
                self.tunnelState = tunnelState
            })
    }

    /// Maps `NEVPNStatus` to `TunnelState`.
    /// Collects the `TunnelConnectionInfo` from the tunnel via IPC if needed before assigning the
    /// `tunnelState`
    private func mapTunnelState(connectionStatus: NEVPNStatus) -> AnyPublisher<TunnelState, MapConnectionStatusError> {
        Just(connectionStatus)
            .setFailureType(to: MapConnectionStatusError.self)
            .flatMap { (connectionStatus) -> AnyPublisher<TunnelState, MapConnectionStatusError> in
                switch connectionStatus {
                case .connected:
                    return self.getTunnelConnectionInfo()
                        .mapError { .ipcRequest($0) }
                        .map { .connected($0) }
                        .eraseToAnyPublisher()

                case .connecting:
                    return Result.Publisher(TunnelState.connecting)
                        .eraseToAnyPublisher()

                case .disconnected:
                    return Result.Publisher(TunnelState.disconnected)
                        .eraseToAnyPublisher()

                case .disconnecting:
                    return Result.Publisher(TunnelState.disconnecting)
                        .eraseToAnyPublisher()

                case .reasserting:
                    // Refresh the last known public key on reconnect to cover the possibility of
                    // the key being changed due to key rotation.
                    if let accountToken = self.accountToken {
                        self.loadPublicKey(accountToken: accountToken)
                    }

                    return self.getTunnelConnectionInfo()
                        .mapError { .ipcRequest($0) }
                        .map { .reconnecting($0) }
                        .eraseToAnyPublisher()

                case .invalid:
                    return Fail(error: MapConnectionStatusError.invalidConfiguration)
                        .eraseToAnyPublisher()

                @unknown default:
                    return Fail(error: MapConnectionStatusError.unknownStatus(connectionStatus))
                        .eraseToAnyPublisher()
                }
        }.eraseToAnyPublisher()
    }

    /// Retrieve the existing TunnelConfiguration or create a new one
    private func makeTunnelConfiguration(accountToken: String) -> Result<TunnelSettings, TunnelManager.Error> {
        TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
            .map { $0.tunnelConfiguration }
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

    private func pushWireguardKeyIfNeeded(accountToken: String) -> AnyPublisher<(), TunnelManager.Error> {
        return TunnelSettingsManager.load(searchTerm: .accountToken(accountToken))
            .publisher
            .mapError {TunnelManager.Error.readTunnelSettings($0) }
            .flatMap { (keychainEntry) -> AnyPublisher<(), TunnelManager.Error> in
                let tunnelSettings = keychainEntry.tunnelConfiguration

                // Make sure to avoid pushing the wireguard keys when addresses are assigned
                guard tunnelSettings.interface.addresses.isEmpty else {
                    return Result.Publisher(()).eraseToAnyPublisher()
                }

                let publicKey = tunnelSettings.interface.privateKey.publicKey

                return self.rpc.pushWireguardKey(
                    accountToken: accountToken,
                    publicKey: publicKey.rawRepresentation
                ).publisher
                    .mapError { TunnelManager.Error.pushWireguardKey($0) }
                    .receive(on: self.executionQueue)
                    .flatMap { (addresses) in
                        return TunnelSettingsManager.update(searchTerm: .accountToken(accountToken)) {
                            (tunnelSettings) in
                            tunnelSettings.interface.addresses = [
                                addresses.ipv4Address,
                                addresses.ipv6Address
                            ]
                        }.mapError { TunnelManager.Error.updateTunnelSettings($0) }
                            .map { _ in () }
                            .publisher
                }.eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    private func setupTunnel(accountToken: String) -> AnyPublisher<TunnelProviderManagerType, TunnelManager.Error> {
        TunnelProviderManagerType.loadAllFromPreferences()
            .receive(on: executionQueue)
            .mapError { TunnelManager.Error.loadAllVPNConfigurations($0) }
            .map { (tunnels) in
                // Return the first available tunnel or make a new one
                return tunnels?.first ?? TunnelProviderManagerType()
        }
        .flatMap { (tunnelProvider) in
            TunnelSettingsManager.getPersistentKeychainReference(account: accountToken)
                .mapError { TunnelManager.Error.obtainPersistentKeychainReference($0) }
                .map { (tunnelProvider, $0) }
                .publisher
        }
        .flatMap { (tunnelProvider, passwordReference) -> AnyPublisher<TunnelProviderManagerType, TunnelManager.Error> in
            tunnelProvider.isEnabled = true
            tunnelProvider.localizedDescription = "WireGuard"
            tunnelProvider.protocolConfiguration = self.makeProtocolConfiguration(
                accountToken: accountToken,
                passwordReference: passwordReference
            )

            // Enable on-demand VPN, always connect the tunnel when on Wi-Fi or cellular
            let alwaysOnRule = NEOnDemandRuleConnect()
            alwaysOnRule.interfaceTypeMatch = .any
            tunnelProvider.onDemandRules = [alwaysOnRule]
            tunnelProvider.isOnDemandEnabled = true

            return tunnelProvider.saveToPreferences()
                .mapError { TunnelManager.Error.saveVPNConfiguration($0) }
                .flatMap {
                    // Refresh connection status after saving the tunnel preferences.
                    // Basically it's only necessary to do for new instances of
                    // `NETunnelProviderManager`, but we do that for the existing ones too for
                    // simplicity as it has no side effects.
                    tunnelProvider.loadFromPreferences()
                        .mapError { TunnelManager.Error.reloadVPNConfiguration($0) }
            }
            .map { tunnelProvider }
            .receive(on: self.executionQueue)
            .handleEvents(receiveCompletion: { (completion) in
                if case .finished = completion {
                    self.setTunnelProvider(tunnelProvider: tunnelProvider)
                }
            }).eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    /// Produce the new tunnel provider protocol configuration
    private func makeProtocolConfiguration(accountToken: String, passwordReference: Data) -> NETunnelProviderProtocol {
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = ApplicationConfiguration.packetTunnelExtensionIdentifier
        protocolConfig.serverAddress = ""
        protocolConfig.username = accountToken
        protocolConfig.passwordReference = passwordReference

        return protocolConfig
    }

    private func migrateTunnelConfiguration(accountToken: String) {
        let result = TunnelSettingsManager
            .migrateKeychainEntry(searchTerm: .accountToken(accountToken))

        switch result {
        case .success(let migrated):
            if migrated {
                os_log("Migrated Keychain tunnel configuration")
            } else {
                os_log("Tunnel configuration is up to date. No migration needed.")
            }

        case .failure(let error):
            os_log("Failed to migrate tunnel configuration: %{public}s",
                   error.localizedDescription)
        }
    }

}

/// Convenience methods to provide `Future` based alternatives for working with
/// `TunnelProviderManager`
private extension VPNTunnelProviderManagerProtocol {

    static func loadAllFromPreferences() -> Future<[SelfType]?, Error> {
        Future { (fulfill) in
            self.loadAllFromPreferences { (tunnels, error) in
                fulfill(error.flatMap { .failure($0) } ?? .success(tunnels))
            }
        }
    }

    func loadFromPreferences() -> Future<(), Error> {
        Future { (fulfill) in
            self.loadFromPreferences { (error) in
                fulfill(error.flatMap { .failure($0) } ?? .success(()))
            }
        }
    }

    func saveToPreferences() -> Future<(), Error> {
        Future { (fulfill) in
            self.saveToPreferences { (error) in
                fulfill(error.flatMap { .failure($0) } ?? .success(()))
            }
        }
    }

    func removeFromPreferences() -> Future<(), Error> {
        Future { (fulfill) in
            self.removeFromPreferences { (error) in
                fulfill(error.flatMap { .failure($0) } ?? .success(()))
            }
        }
    }

}
