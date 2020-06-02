//
//  ErrorPresentation.swift
//  MullvadVPN
//
//  Created by pronebird on 11/12/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

protocol ErrorPresentation {
    associatedtype Cause: Error
    associatedtype Context

    /// Cause of error
    var cause: Cause { get }

    /// Presentation context
    var context: Context { get }

    /// Alert title
    var title: String? { get }

    /// Alert message
    var message: String? { get }

    /// A recovery suggestion, added to the alert message if provided
    var recoverySuggestion: String? { get }

    /// Presentation style
    var preferredStyle: UIAlertController.Style { get }

    /// Actions
    var actions: [UIAlertAction] { get }

    /// Default initializer
    init(context: Context, cause: Cause)
}

extension ErrorPresentation where Context == Void {
    init(cause: Cause) {
        self.init(context: (), cause: cause)
    }
}

extension ErrorPresentation {
    var alertController: UIAlertController {
        let message = [self.message, recoverySuggestion]
            .compactMap { $0 }.joined(separator: "\n\n")

        let alertController = UIAlertController(
            title: title,
            message: message,
            preferredStyle: preferredStyle
        )

        actions.forEach { alertController.addAction($0) }

        return alertController
    }
}

struct NoContextError: ErrorPresentation {

    typealias Cause = Error
    typealias Context = Void

    var context: Void
    var cause: Error

    var title: String? {
        return nil
    }

    var message: String? {
        return nil
    }

    var recoverySuggestion: String? {
        return nil
    }

    var preferredStyle: UIAlertController.Style {
        return .actionSheet
    }

    var actions: [UIAlertAction] {
        return []
    }
}
