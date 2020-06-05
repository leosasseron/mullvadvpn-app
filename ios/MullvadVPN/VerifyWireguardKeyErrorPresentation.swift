//
//  VerifyWireguardKeyErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 04/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

struct VerifyWireguardKeyErrorPresentation: ErrorPresentation {

    var context: Void
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

        case .encoding:
            return NSLocalizedString("Server request encoding error", comment: "")

        case .decoding:
            return NSLocalizedString("Server response decoding error", comment: "")
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
