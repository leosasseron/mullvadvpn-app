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
    var cause: TunnelManagerError

    var title: String? {
        switch context {
        case .startTunnel:
            return NSLocalizedString("Cannot start tunnel", comment: "")

        case .stopTunnel:
            return NSLocalizedString("Cannot stop tunnel", comment: "")

        case .regenerateKey:
            return NSLocalizedString("Cannot regenerate key", comment: "")
        }
    }

    var message: String? {
        switch cause {
        case .startTunnel(let error):
            switch error {
            case .system(let systemError):
                return String(format: NSLocalizedString("System error: %@", comment: ""), systemError.localizedDescription)
            case .setup(let setupError):
                switch setupError {
                case .loadTunnels(let systemError):
                    return String(format: NSLocalizedString("Failure to load system VPN configurations: %@", comment: ""), systemError.localizedDescription)

                case .reloadTunnel(let systemError):
                    return String(format: NSLocalizedString("Failure to reload a VPN configuration: %@", comment: ""), systemError.localizedDescription)

                case .saveTunnel(let systemError):
                    return String(format: NSLocalizedString("Failure to save a VPN tunnel configuration: %@", comment: ""), systemError.localizedDescription)

                case .obtainKeychainRef(_):
                    return NSLocalizedString("Failure obtaining the keychain reference for the VPN configuration", comment: "")
                }
            }

        case .stopTunnel(let systemError):
            return String(format: NSLocalizedString("System error: %@", comment: ""), systemError.localizedDescription)

        case .regenerateWireguardPrivateKey(let error):
            switch error {
            case .readPublicWireguardKey(_):
                return NSLocalizedString("Failed to read the existing public key", comment: "")

            case .replaceWireguardKey(let error):
                switch error {
                case .network(let urlError):
                    return String(format: NSLocalizedString("Network error: %@", comment: ""), urlError.localizedDescription)
                case .server(let serverError):
                    return String(format: NSLocalizedString("Server error: %@", comment: ""), serverError.localizedDescription)
                case .decoding(_):
                    return NSLocalizedString("Decoding error", comment: "")
                case .encoding(_):
                    return NSLocalizedString("Encoding error", comment: "")
                }

            case .updateTunnelConfiguration(_):
                return NSLocalizedString("Failure to update VPN tunnel configuration", comment: "")
            }
        default:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch cause {
        case .regenerateWireguardPrivateKey(.replaceWireguardKey(.server(let serverError)))
            where serverError.code == .tooManyWireguardKeys:
            return NSLocalizedString("Remove unused WireGuard keys and try again.", comment: "")

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

}
