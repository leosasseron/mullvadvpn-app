//
//  AppStorePaymentManager.swift
//  MullvadVPN
//
//  Created by pronebird on 10/03/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import StoreKit
import os

enum AppStoreSubscription: String {
    /// Thirty days non-renewable subscription
    case thirtyDays = "net.mullvad.MullvadVPN.subscription.30days"

    var localizedTitle: String {
        switch self {
        case .thirtyDays:
            return NSLocalizedString("Add 30 days time", comment: "")
        }
    }
}

extension SKProduct {
    var customLocalizedTitle: String? {
        return AppStoreSubscription(rawValue: productIdentifier)?.localizedTitle
    }
}

extension Set where Element == AppStoreSubscription {
    var productIdentifiersSet: Set<String> {
        Set<String>(self.map { $0.rawValue })
    }
}

protocol AppStorePaymentObserver: class {
    func appStorePaymentManager(
        _ manager: AppStorePaymentManager,
        transaction: SKPaymentTransaction,
        didFailWithError error: AppStorePaymentManager.Error)

    func appStorePaymentManager(
        _ manager: AppStorePaymentManager,
        transaction: SKPaymentTransaction,
        didFinishWithResponse response: SendAppStoreReceiptResponse)
}

/// A type-erasing weak container for `AppStorePaymentObserver`
private class WeakAppStorePaymentObserverBox: AppStorePaymentObserver {
    private(set) weak var observer: AppStorePaymentObserver?

    init<T: AppStorePaymentObserver>(observer: T) {
        self.observer = observer
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager,
                                transaction: SKPaymentTransaction,
                                didFailWithError error: AppStorePaymentManager.Error)
    {
        self.observer?.appStorePaymentManager(manager, transaction: transaction, didFailWithError: error)
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager,
                                transaction: SKPaymentTransaction,
                                didFinishWithResponse response: SendAppStoreReceiptResponse)
    {
        self.observer?.appStorePaymentManager(manager,
                                         transaction: transaction,
                                         didFinishWithResponse: response)
    }

}

protocol AppStorePaymentManagerDelegate: class {

    /// Return the account token associated with the payment.
    /// Usually called for unfinished transactions coming back after the app was restarted.
    func appStorePaymentManager(_ manager: AppStorePaymentManager,
                                didRequestAccountTokenFor payment: SKPayment) -> String?
}

class AppStorePaymentManager: NSObject, SKPaymentTransactionObserver {

    enum Error: ChainedError {
        case noAccountSet
        case storePayment(Swift.Error)
        case readReceipt(AppStoreReceipt.Error)
        case sendReceipt(MullvadRpc.Error)

        var errorDescription: String? {
            switch self {
            case .noAccountSet:
                return "Account is not set"
            case .storePayment:
                return "Store payment error"
            case .readReceipt:
                return "Read recept error"
            case .sendReceipt:
                return "Send receipt error"
            }
        }
    }

    /// A shared instance of `AppStorePaymentManager`
    static let shared = AppStorePaymentManager(queue: SKPaymentQueue.default())

    private let operationQueue = OperationQueue()
    private let queue: SKPaymentQueue
    private let rpc = MullvadRpc.withEphemeralURLSession()

    private var observers = [WeakAppStorePaymentObserverBox]()
    private let lock = NSRecursiveLock()

    private weak var classDelegate: AppStorePaymentManagerDelegate?
    weak var delegate: AppStorePaymentManagerDelegate? {
        get {
            lock.withCriticalBlock {
                return classDelegate
            }
        }
        set {
            lock.withCriticalBlock {
                classDelegate = newValue
            }
        }
    }

    /// A private hash map that maps each payment to account token
    private var paymentToAccountToken = [SKPayment: String]()

    /// Returns true if the device is able to make payments
    class var canMakePayments: Bool {
        return SKPaymentQueue.canMakePayments()
    }

    init(queue: SKPaymentQueue) {
        self.queue = queue
    }

    func startPaymentQueueMonitoring() {
        queue.add(self)
    }

    // MARK: - SKPaymentTransactionObserver

    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            self.handleTransaction(transaction)
        }
    }

    // MARK: - Payment observation

    func addPaymentObserver<T: AppStorePaymentObserver>(_ observer: T) {
        lock.withCriticalBlock {
            let boxed = WeakAppStorePaymentObserverBox(observer: observer)

            self.observers.append(boxed)
        }
    }

    func removePaymentObserver(_ observer: AppStorePaymentObserver) {
        lock.withCriticalBlock {
            self.observers.removeAll { (box) -> Bool in
                return box.observer === observer
            }
        }
    }

    private func enumerateObservers(_ block: (AppStorePaymentObserver) -> Void) {
        lock.withCriticalBlock {
            var discardIndices = [Int]()

            self.observers.enumerated().forEach { (index, anyObserver) in
                if anyObserver.observer == nil {
                    discardIndices.append(index)
                } else {
                    block(anyObserver)
                }
            }

            discardIndices.reversed().forEach { (index) in
                self.observers.remove(at: index)
            }
        }
    }

    // MARK: - Account token and payment mapping

    private func associateAccountToken(_ token: String, and payment: SKPayment) {
        lock.withCriticalBlock {
            paymentToAccountToken[payment] = token
        }
    }

    private func deassociateAccountToken(_ payment: SKPayment) -> String? {
        return lock.withCriticalBlock {
            if let accountToken = paymentToAccountToken[payment] {
                paymentToAccountToken.removeValue(forKey: payment)
                return accountToken
            } else {
                return self.classDelegate?
                    .appStorePaymentManager(self, didRequestAccountTokenFor: payment)
            }
        }
    }

    // MARK: - Products and payments

    func requestProducts(with productIdentifiers: Set<AppStoreSubscription>,
                         completionHandler: @escaping (Result<SKProductsResponse, Swift.Error>) -> Void)
    {
        let productIdentifiers = productIdentifiers.productIdentifiersSet
        let request = SKProductsRequest(productIdentifiers: productIdentifiers)
        let operation = ProductsRequestOperation(request: request)
        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        operationQueue.addOperation(operation)
    }

    func addPayment(_ payment: SKPayment, for accountToken: String) {
        associateAccountToken(accountToken, and: payment)
        queue.add(payment)
    }

    func restorePurchases(
        for accountToken: String,
        completionHandler: @escaping (Result<SendAppStoreReceiptResponse, AppStorePaymentManager.Error>) -> Void) {
        return sendAppStoreReceipt(
            accountToken: accountToken,
            forceRefresh: true,
            completionHandler: completionHandler
        )
    }

    // MARK: - Private methods

    private func sendAppStoreReceipt(accountToken: String, forceRefresh: Bool, completionHandler: @escaping (Result<SendAppStoreReceiptResponse, Error>) -> Void)
    {
        AppStoreReceipt.fetch(forceRefresh: forceRefresh) { (result) in
            switch result {
            case .success(let receiptData):
                let request = self.rpc.sendAppStoreReceipt(
                    accountToken: accountToken,
                    receiptData: receiptData
                )

                let urlSessionTask = request.dataTask { (result) in
                    switch result {
                    case .success(let response):
                        os_log(
                            .info,
                            "AppStore Receipt was processed. Time added: %{public}.2f, New expiry: %{private}s",
                            response.timeAdded, "\(response.newExpiry)")

                        completionHandler(.success(response))

                    case .failure(let error):
                        completionHandler(.failure(.sendReceipt(error)))
                    }
                }

                urlSessionTask?.resume()

            case .failure(let error):
                completionHandler(.failure(.readReceipt(error)))
            }
        }
    }

    private func handleTransaction(_ transaction: SKPaymentTransaction) {
        switch transaction.transactionState {
        case .deferred:
            os_log(.debug, "Deferred %{public}s", transaction.payment.productIdentifier)

        case .failed:
            os_log(.debug, "Failed to purchase %{public}s: %{public}s",
                   transaction.payment.productIdentifier,
                   transaction.error?.localizedDescription ?? "No error")

            didFailPurchase(transaction: transaction)

        case .purchased:
            os_log(.debug, "Purchased %{public}s", transaction.payment.productIdentifier)

            didFinishOrRestorePurchase(transaction: transaction)

        case .purchasing:
            os_log(.debug, "Purchasing %{public}s", transaction.payment.productIdentifier)

        case .restored:
            os_log(.debug, "Restored %{public}s", transaction.payment.productIdentifier)

            didFinishOrRestorePurchase(transaction: transaction)

        @unknown default:
            os_log(.debug, "Unknown transactionState = %{public}d",
                   transaction.transactionState.rawValue)
        }
    }

    private func didFailPurchase(transaction: SKPaymentTransaction) {
        queue.finishTransaction(transaction)

        enumerateObservers { (observer) in
            observer.appStorePaymentManager(
                self,
                transaction: transaction,
                didFailWithError: .storePayment(transaction.error!))
        }

        _ = deassociateAccountToken(transaction.payment)
    }

    private func didFinishOrRestorePurchase(transaction: SKPaymentTransaction) {
        guard let accountToken = deassociateAccountToken(transaction.payment) else {
            enumerateObservers { (observer) in
                observer.appStorePaymentManager(
                    self,
                    transaction: transaction,
                    didFailWithError: .noAccountSet)
            }
            return
        }

        sendAppStoreReceipt(accountToken: accountToken, forceRefresh: false) { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    self.queue.finishTransaction(transaction)

                    self.enumerateObservers { (observer) in
                        observer.appStorePaymentManager(
                            self,
                            transaction: transaction,
                            didFinishWithResponse: response)
                    }

                case .failure(let error):
                    os_log("%{public}s", error.displayChain(message: "Failed to upload the AppStore receipt"))

                    self.enumerateObservers { (observer) in
                        observer.appStorePaymentManager(
                            self,
                            transaction: transaction,
                            didFailWithError: error)
                    }
                }
            }
        }
    }

}

private class ProductsRequestOperation: AsyncOutputOperation<Result<SKProductsResponse, Error>>, SKProductsRequestDelegate {
    private let request: SKProductsRequest

    init(request: SKProductsRequest) {
        self.request = request
        super.init()

        request.delegate = self
    }

    override func main() {
        request.start()
    }

    override func cancel() {
        super.cancel()

        request.cancel()
    }

    // - MARK: SKProductsRequestDelegate

    func requestDidFinish(_ request: SKRequest) {
        //finish(with: .success(()))
        // no-op
    }

    func request(_ request: SKRequest, didFailWithError error: Error) {
        finish(with: .failure(error))
    }

    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        finish(with: .success(response))
    }
}
