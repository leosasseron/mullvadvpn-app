//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Created by pronebird on 19/03/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Network
import NetworkExtension
import os

enum PacketTunnelProviderError: ChainedError {
    /// Failure to read the relay cache
    case readRelayCache(RelayCacheError)

    /// Failure to satisfy the relay constraint
    case noRelaySatisfyingConstraint

    /// Missing the persistent keychain reference to the tunnel configuration
    case missingKeychainConfigurationReference

    /// Failure to read the tunnel configuration from Keychain
    case cannotReadTunnelConfiguration(TunnelSettingsManager.Error)

    /// Failure to set network settings
    case setNetworkSettings(Error)

    /// Failure to start the Wireguard backend
    case startWireguardDevice(WireguardDevice.Error)

    /// Failure to update the Wireguard configuration
    case updateWireguardConfiguration(Error)

    /// IPC handler failure
    case ipcHandler(PacketTunnelIpcHandler.Error)

    var errorDescription: String? {
        switch self {
        case .readRelayCache:
            return "Failure to read the relay cache"

        case .noRelaySatisfyingConstraint:
            return "No relay satisfying the given constraint"

        case .missingKeychainConfigurationReference:
            return "Invalid protocol configuration"

        case .cannotReadTunnelConfiguration:
            return "Failure reading tunnel configuration"

        case .setNetworkSettings:
            return "Failure to set system network settings"

        case .startWireguardDevice:
            return "Failure starting WireGuard device"

        case .updateWireguardConfiguration:
            return "Failure to update Wireguard configuration"

        case .ipcHandler:
            return "Failure to handle the IPC request"
        }
    }
}

struct PacketTunnelConfiguration {
    var persistentKeychainReference: Data
    var tunnelConfig: TunnelSettings
    var selectorResult: RelaySelectorResult
}

extension PacketTunnelConfiguration {
    var wireguardConfig: WireguardConfiguration {
        let mullvadEndpoint = selectorResult.endpoint
        var peers: [AnyIPEndpoint] = [.ipv4(mullvadEndpoint.ipv4Relay)]

        if let ipv6Relay = mullvadEndpoint.ipv6Relay {
            peers.append(.ipv6(ipv6Relay))
        }

        let wireguardPeers = peers.map {
            WireguardPeer(
                endpoint: $0,
                publicKey: selectorResult.endpoint.publicKey)
        }

        return WireguardConfiguration(
            privateKey: tunnelConfig.interface.privateKey,
            peers: wireguardPeers,
            allowedIPs: [
                IPAddressRange(address: IPv4Address.any, networkPrefixLength: 0),
                IPAddressRange(address: IPv6Address.any, networkPrefixLength: 0)
            ]
        )
    }
}

class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Active wireguard device
    private var wireguardDevice: WireguardDevice?

    /// Active tunnel connection information
    private var connectionInfo: TunnelConnectionInfo?

    /// The completion handler to call when the tunnel is fully established.
    var pendingStartCompletion: ((Error?) -> Void)?

    /// The completion handler to call when the tunnel is fully disconnected.
    var pendingStopCompletion: (() -> Void)?

    private let operationQueue = OperationQueue()

    private var keyRotationManager: AutomaticKeyRotationManager?

    override init() {
        super.init()

        self.configureLogger()
    }

    // MARK: - Subclass

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        pendingStartCompletion = completionHandler
        pendingStopCompletion = nil

        os_log(.default, log: tunnelProviderLog, "Start the tunnel")

        makePacketTunnelConfigAndApplyNetworkSettings { (result) in
            switch result {
            case .success(let packetTunnelConfig):
                Self.startWireguard(packetFlow: self.packetFlow, configuration: packetTunnelConfig.wireguardConfig) { (result) in
                    switch result {
                    case .success(let device):
                        self.wireguardDevice = device
                        self.startKeyRotation(persistentKeychainReference: packetTunnelConfig.persistentKeychainReference)

                    case .failure(let error):
                        os_log(.error, log: tunnelProviderLog, "%{public}s", error.displayChain())
                    }
                }

            case .failure(let error):
                os_log(.error, log: tunnelProviderLog, "%{public}s", error.displayChain())
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        pendingStartCompletion = nil
        pendingStopCompletion = completionHandler

        os_log(.default, log: tunnelProviderLog,
               "Stop the tunnel. Reason: %{public}s", "\(reason)")

        self.stopKeyRotation()

        if let device = self.wireguardDevice {
            self.wireguardDevice = nil
            
            device.stop { (result) in
                // Ignore all errors at this point
                self.pendingStopCompletion?()
            }
        } else {
            self.pendingStopCompletion?()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let finishWithResult = { (result: Result<AnyEncodable, PacketTunnelProviderError>) in
            let result = result.flatMap { (response) -> Result<Data, PacketTunnelProviderError> in
                return PacketTunnelIpcHandler.encodeResponse(response: response)
                    .mapError { PacketTunnelProviderError.ipcHandler($0) }
            }

            switch result {
            case .success(let data):
                completionHandler?(data)

            case .failure(let error):
                os_log(.error, log: tunnelProviderLog, "%{public}s", error.displayChain())
                completionHandler?(nil)
            }
        }

        let decodeResult = PacketTunnelIpcHandler.decodeRequest(messageData: messageData)
            .mapError { PacketTunnelProviderError.ipcHandler($0) }

        switch decodeResult {
        case .success(let request):
            switch request {
            case .reloadTunnelSettings:
                self.reloadTunnelSettings { (result) in
                    let result = result.map { AnyEncodable(true) }
                    finishWithResult(result)
                }

            case .tunnelInformation:
                finishWithResult(.success(AnyEncodable(self.connectionInfo)))
            }

        case .failure(let error):
            finishWithResult(.failure(error))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }

    override func wake() {
        // Add code here to wake up.
    }

    // MARK: - Private

    private func configureLogger() {
        WireguardDevice.setLogger { (level, message) in
            os_log(level.osLogType, log: wireguardLog, "%{public}s", message)
        }
    }

    private func setTunnelConnectionInfo(selectorResult: RelaySelectorResult) {
        self.connectionInfo = TunnelConnectionInfo(
            ipv4Relay: selectorResult.endpoint.ipv4Relay,
            ipv6Relay: selectorResult.endpoint.ipv6Relay,
            hostname: selectorResult.relay.hostname,
            location: selectorResult.location
        )

        os_log(.default, log: tunnelProviderLog, "Select relay: %{public}s",
               selectorResult.relay.hostname)
    }

    /// Make and return `PacketTunnelConfig` after applying network settings and setting the
    /// tunnel connection info
    private func makePacketTunnelConfigAndApplyNetworkSettings(completionHandler: @escaping (Result<PacketTunnelConfiguration, PacketTunnelProviderError>) -> Void) {
        self.makePacketTunnelConfig { (result) in
            switch result {
            case .success(let packetTunnelConfig):
                // TODO: Fix threading
                self.setTunnelConnectionInfo(selectorResult: packetTunnelConfig.selectorResult)

                let settingsGenerator = PacketTunnelSettingsGenerator(
                    mullvadEndpoint: packetTunnelConfig.selectorResult.endpoint,
                    tunnelConfiguration: packetTunnelConfig.tunnelConfig
                )

                os_log(.default, log: tunnelProviderLog, "Set tunnel network settings")

                self.setTunnelNetworkSettings(settingsGenerator.networkSettings()) { (error) in
                    if let error = error{
                        os_log(.error, log: tunnelProviderLog, "Cannot set network settings: %{public}s", error.localizedDescription)

                        completionHandler(.failure(.setNetworkSettings(error)))
                    } else {
                        completionHandler(.success(packetTunnelConfig))
                    }
                }

            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    /// Returns a `PacketTunnelConfig` that contains the tunnel configuration and selected relay
    private func makePacketTunnelConfig(completionHandler: @escaping (Result<PacketTunnelConfiguration, PacketTunnelProviderError>) -> Void) {
        guard let keychainReference = protocolConfiguration.passwordReference else {
            completionHandler(.failure(.missingKeychainConfigurationReference))
            return
        }

        switch Self.readTunnelConfiguration(keychainReference: keychainReference) {
        case .success(let tunnelSettings):
            Self.selectRelayEndpoint(relayConstraints: tunnelSettings.relayConstraints) { (result) in
                let result = result.map { (selectorResult) -> PacketTunnelConfiguration in
                    return PacketTunnelConfiguration(
                        persistentKeychainReference: keychainReference,
                        tunnelConfig: tunnelSettings,
                        selectorResult: selectorResult
                    )
                }
                completionHandler(result)
            }

        case .failure(let error):
            completionHandler(.failure(error))
        }
    }

    private func reloadTunnelSettings(completionHandler: @escaping (Result<(), PacketTunnelProviderError>) -> Void) {
        guard let wireguardDevice = self.wireguardDevice else {
            os_log(.default, log: tunnelProviderLog, "Ignore reloading tunnel settings. The WireguardDevice is not set yet.")

            completionHandler(.success(()))
            return
        }

        os_log(.default, log: tunnelProviderLog, "Reload tunnel settings")

        let finish = { (result: Result<(), PacketTunnelProviderError>) in
            // Tell the system that the tunnel has finished reconnecting
            self.reasserting = false

            completionHandler(result)
        }

        // Tell the system that the tunnel is about to reconnect with the new endpoint
        self.reasserting = true

        makePacketTunnelConfigAndApplyNetworkSettings { (result) in
            switch result {
            case .success(let packetTunnelConfig):
                wireguardDevice.setConfig(configuration: packetTunnelConfig.wireguardConfig) { (result) in
                    let result = result.mapError {
                        PacketTunnelProviderError.updateWireguardConfiguration($0)
                    }

                    finish(result)
                }

            case .failure(let error):
                finish(.failure(error))
            }
        }
    }

    private func startKeyRotation(persistentKeychainReference: Data) {
        let keyRotationManager = AutomaticKeyRotationManager(
            persistentKeychainReference: persistentKeychainReference
        )

        keyRotationManager.eventHandler = { (keyRotationEvent) in
            self.reloadTunnelSettings { (result) in
                switch result {
                case .success:
                    break

                case .failure(let error):
                    os_log(.error, log: tunnelProviderLog, "%{public}s", error.displayChain(message: "Failed to reload tunnel settings"))
                }
            }
        }

        stopKeyRotation()
        self.keyRotationManager = keyRotationManager

        keyRotationManager.startAutomaticRotation()
    }


    private func stopKeyRotation() {
        keyRotationManager?.stopAutomaticRotation()
        keyRotationManager = nil
    }

    /// Read tunnel configuration from Keychain
    private class func readTunnelConfiguration(keychainReference: Data) -> Result<TunnelSettings, PacketTunnelProviderError> {
        TunnelSettingsManager.load(searchTerm: .persistentReference(keychainReference))
            .mapError { PacketTunnelProviderError.cannotReadTunnelConfiguration($0) }
            .map { $0.tunnelConfiguration }
    }

    /// Load relay cache with potential networking to refresh the cache and pick the relay for the
    /// given relay constraints.
    private class func selectRelayEndpoint(relayConstraints: RelayConstraints, completionHandler: @escaping (Result<RelaySelectorResult, PacketTunnelProviderError>) -> Void) {
        let relayCache = RelayCache.withDefaultLocationAndEphemeralSession()
        switch relayCache {
        case .success(let relayCache):
            relayCache.read { (result) in
                switch result {
                case .success(let cachedRelayList):
                    let relaySelector = RelaySelector(relayList: cachedRelayList.relayList)

                    if let selectorResult = relaySelector.evaluate(with: relayConstraints) {
                        completionHandler(.success(selectorResult))
                    } else {
                        completionHandler(.failure(.noRelaySatisfyingConstraint))
                    }

                case .failure(let error):
                    completionHandler(.failure(.readRelayCache(error)))
                }
            }

        case .failure(let error):
            completionHandler(.failure(.readRelayCache(error)))
        }
    }

    private class func startWireguard(packetFlow: NEPacketTunnelFlow, configuration: WireguardConfiguration, completionHandler: @escaping (Result<WireguardDevice, PacketTunnelProviderError>) -> Void) {

        switch WireguardDevice.fromPacketFlow(packetFlow) {
        case .success(let device):
            os_log(.default, log: tunnelProviderLog,
                   "Tunnel interface is %{public}s",
                   device.getInterfaceName() ?? "unknown")

            device.start(configuration: configuration) { (result) in
                switch result {
                case .success:
                    completionHandler(.success(device))

                case .failure(let error):
                    completionHandler(.failure(.startWireguardDevice(error)))
                }
            }

        case .failure(let error):
            completionHandler(.failure(.startWireguardDevice(error)))
        }
    }
}
