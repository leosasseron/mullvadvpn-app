//
//  AlertPresenter.swift
//  MullvadVPN
//
//  Created by pronebird on 04/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

class AlertPresenter {
    private var operationQueue = OperationQueue()
    private var lastOperation: Operation?

    func enqueue(_ alertController: UIAlertController, presentingController: UIViewController) {
        assert(Thread.isMainThread)

        let operation = PresentAlertOperation(
            alertController: alertController,
            presentingController: presentingController
        )

        if let lastOperation = lastOperation {
            operation.addDependency(lastOperation)
        }

        lastOperation = operation

        operationQueue.addOperation(operation)
    }
}

private class PresentAlertOperation: AsyncOperation {
    private let alertController: UIAlertController
    private let presentingController: UIViewController
    private var dismissalObserver: NSObjectProtocol?

    init(alertController: UIAlertController, presentingController: UIViewController) {
        self.alertController = alertController
        self.presentingController = presentingController

        super.init()
    }

    override func main() {
        DispatchQueue.main.async {
            self.dismissalObserver = NotificationCenter.default.addObserver(
                forName: .UIPresentationControllerDismissalTransitionDidEndNotification,
                object: self.alertController,
                queue: nil,
                using: { [weak self] (note) in
                    self?.finish()
            })

            self.presentingController.present(self.alertController, animated: true)
        }
    }
}

extension Notification.Name {
    /// A private UIKit notification that `UIPresentationController` sends upon dismissal.
    static var UIPresentationControllerDismissalTransitionDidEndNotification = Notification.Name("UIPresentationControllerDismissalTransitionDidEndNotification")
}
