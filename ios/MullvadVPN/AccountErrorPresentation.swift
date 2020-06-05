//
//  AccountErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 05/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

struct AccountErrorPresentation: ErrorPresentation {
    enum Context {
        case login, logout
    }

    var context: Context
    var cause: Account.Error

    var title: String? {
        switch context {
        case .login:
            return NSLocalizedString("Failed to log in", comment: "")
        case .logout:
            return NSLocalizedString("Failed to log out", comment: "")
        }
    }

    var message: String? {
        switch cause {
        case .createAccount(let rpcError):
            return String(format: NSLocalizedString("Cannot create a new account: %@", comment: ""), describeRpcError(rpcError))


        case .verifyAccount(let rpcError):
            return String(format: NSLocalizedString("Cannot verifty the account: %@", comment: ""), describeRpcError(rpcError))
            
        case .tunnelConfiguration:
            return NSLocalizedString("Internal error", comment: "")
        }
    }

    var recoverySuggestion: String? {
        return nil
    }

    var preferredStyle: UIAlertController.Style {
        return .alert
    }

    var actions: [UIAlertAction] {
        return [UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default)]
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
