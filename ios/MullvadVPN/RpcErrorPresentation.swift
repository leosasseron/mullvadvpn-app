//
//  RpcErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 04/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

struct RpcErrorPresentation: ErrorPresentation {

    enum Context {
        case verifyKey
    }

    var context: Context
    var cause: MullvadRpc.Error

    var title: String? {
        return NSLocalizedString("Cannot verify the public key", comment: "")
    }

    var message: String? {
        switch cause {
        case .network(let urlError):
            return urlError.localizedDescription

        case .server(let serverError):
            return serverError.errorDescription

        case .decoding, .encoding:
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
        return [
            UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil)
        ]
    }

}
