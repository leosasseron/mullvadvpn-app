//
//  AppStorePaymentErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 05/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

struct AppStorePaymentErrorPresentation: ErrorPresentation {
    enum Context {
        case purchase
        case restorePurchases
    }

    var context: Context
    var cause: AppStorePaymentManager.Error

    var title: String? {
        switch context {
        case .purchase:
            return NSLocalizedString("Cannot complete the payment", comment: "")
        case .restorePurchases:
            return NSLocalizedString("Cannot restore purchases", comment: "")
        }
    }

    var message: String? {
        switch cause {
        case .noAccountSet:
            return NSLocalizedString("Internal error: account is not set", comment: "")

        case .readReceipt(let readReceiptError):
            return String(format: NSLocalizedString("Cannot read the receipt: %@", comment: ""), readReceiptError.errorDescription ?? "")

        case .sendReceipt(let rpcError):
            return String(format: NSLocalizedString("Failed to send the receipt to server: %@", comment: ""), self.describeRpcError(rpcError))

        case .storePayment(let storeError):
            return storeError.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        if case .sendReceipt = cause {
            return NSLocalizedString(
                #"Please retry by using the "Restore purchases" button"#, comment: "")
        } else {
            return nil
        }
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
