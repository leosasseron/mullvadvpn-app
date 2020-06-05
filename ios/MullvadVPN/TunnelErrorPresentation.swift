//
//  TunnelErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 04/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit
import NetworkExtension

struct TunnelErrorPresentation: ErrorPresentation {

    enum Context {
        case startTunnel
        case stopTunnel
        case regenerateKey
    }

    var context: Context
    var cause: TunnelManager.Error

    var title: String? {
        switch context {
        case .startTunnel:
            return NSLocalizedString("Cannot start the tunnel", comment: "")

        case .stopTunnel:
            return NSLocalizedString("Cannot stop the tunnel", comment: "")

        case .regenerateKey:
            return NSLocalizedString("Cannot regenerate the key", comment: "")
        }
    }

    var message: String? {
        switch cause {
        case .loadAllVPNConfigurations(let systemError):
            return String(format: NSLocalizedString("Failed to load system VPN configurations: %@", comment: ""), systemError.localizedDescription)

        case .reloadVPNConfiguration(let systemError):
            return String(format: NSLocalizedString("Failed to reload a VPN configuration: %@", comment: ""), systemError.localizedDescription)

        case .saveVPNConfiguration(let systemError):
            return String(format: NSLocalizedString("Failed to save a VPN tunnel configuration: %@", comment: ""), systemError.localizedDescription)

        case .obtainPersistentKeychainReference(_):
            return NSLocalizedString("Failed to obtain the persistent keychain reference for the VPN configuration", comment: "")

        case .startVPNTunnel(let systemError):
            return String(format: NSLocalizedString("System error when starting the VPN tunnel: %@", comment: ""), systemError.localizedDescription)

        case .stopVPNTunnel(let systemError):
            return String(format: NSLocalizedString("System error when stopping the VPN tunnel: %@", comment: ""), systemError.localizedDescription)

        case .removeVPNConfiguration(let systemError):
            return String(format: NSLocalizedString("Failed to remove the system VPN configuration: %@", comment: ""), systemError.localizedDescription)

        case .removeInconsistentVPNConfiguration(let systemError):
            return String(format: NSLocalizedString("Failed to remove the outdated system VPN configuration: %@", comment: ""), systemError.localizedDescription)

        case .readTunnelSettings(_):
            return NSLocalizedString("Failed to read the tunnel settings from Keychain", comment: "")

        case .addTunnelSettings(_):
            return NSLocalizedString("Failed to add the tunnel settings in Keychain", comment: "")

        case .updateTunnelSettings(_):
            return NSLocalizedString("Failed to update the tunnel settings in Keychain", comment: "")

        case .removeTunnelSettings(_):
            return NSLocalizedString("Failed to remove the tunnel settings from Keychain", comment: "")

        case .pushWireguardKey(let rpcError):
            return String(format: NSLocalizedString("Cannot send the WireGuard key to server: %@", comment: ""), self.describeRpcError(rpcError))

        case .replaceWireguardKey(let rpcError):
            return String(format: NSLocalizedString("Cannot replace the WireGuard key on server: %@", comment: ""), self.describeRpcError(rpcError))

        case .missingAccount:
            return NSLocalizedString("Internal error", comment: "")
        }
    }

    var recoverySuggestion: String? {
        switch cause {
        case .pushWireguardKey(.server(let serverError)) where serverError.code == .tooManyWireguardKeys, .replaceWireguardKey(.server(let serverError)) where serverError.code == .tooManyWireguardKeys:
            return NSLocalizedString("Remove unused WireGuard keys and try again", comment: "")

        default:
            return nil
        }
    }

    var preferredStyle: UIAlertController.Style {
        return .alert
    }

    var actions: [UIAlertAction] {
        return [
            UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil)
        ]
    }

    private func describeRpcError(_ rpcError: MullvadRpc.Error) -> String {
        switch rpcError {
        case .network(let urlError):
            return urlError.localizedDescription

        case .server(let serverError):
            return serverError.errorDescription ?? serverError.message

        case .encoding:
            return NSLocalizedString("Server request encoding error", comment: "")

        case .decoding:
            return NSLocalizedString("Server response decoding error", comment: "")
        }
    }

}
