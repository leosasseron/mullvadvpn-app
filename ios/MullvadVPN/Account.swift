//
//  Account.swift
//  MullvadVPN
//
//  Created by pronebird on 16/05/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Combine
import Foundation
import NetworkExtension
import StoreKit
import os

/// A enum holding the `UserDefaults` string keys
private enum UserDefaultsKeys: String {
    case isAgreedToTermsOfService = "isAgreedToTermsOfService"
    case accountToken = "accountToken"
    case accountExpiry = "accountExpiry"
}

/// A class that groups the account related operations
class Account {

    enum Error: ChainedError {
        /// A failure to create the new account token
        case createAccount(MullvadRpc.Error)

        /// A failure to verify the account token
        case verifyAccount(MullvadRpc.Error)

        /// A failure to configure a tunnel
        case tunnelConfiguration(TunnelManager.Error)
    }

    /// A notification name used to broadcast the changes to account expiry
    static let didUpdateAccountExpiryNotification = Notification.Name("didUpdateAccountExpiry")

    /// A notification userInfo key that holds the `Date` with the new account expiry
    static let newAccountExpiryUserInfoKey = "newAccountExpiry"

    static let shared = Account()
    private let rpc = MullvadRpc.withEphemeralURLSession()

    /// Returns true if user agreed to terms of service, otherwise false
    var isAgreedToTermsOfService: Bool {
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.isAgreedToTermsOfService.rawValue)
    }

    /// Returns the currently used account token
    var token: String? {
        return UserDefaults.standard.string(forKey: UserDefaultsKeys.accountToken.rawValue)
    }

    var formattedToken: String? {
        return token?.split(every: 4).joined(separator: " ")
    }

    /// Returns the account expiry for the currently used account token
    var expiry: Date? {
        return UserDefaults.standard.object(forKey: UserDefaultsKeys.accountExpiry.rawValue) as? Date
    }

    var isLoggedIn: Bool {
        return token != nil
    }

    /// Save the boolean flag in preferences indicating that the user agreed to terms of service.
    func agreeToTermsOfService() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.isAgreedToTermsOfService.rawValue)
    }

    func loginWithNewAccount() -> AnyPublisher<String, Error> {
        return rpc.createAccount()
            .publisher
            .mapError { .createAccount($0) }
            .flatMap { (newAccountToken) -> Future<(String, Date), Error> in
                return Future({ (fulfill) in
                    TunnelManager.shared.setAccount(accountToken: newAccountToken) { (result) in
                        let result = result
                            .mapError { Error.tunnelConfiguration($0) }
                            .map { (newAccountToken, Date()) }
                        fulfill(result)
                    }
                })
        }
        .receive(on: DispatchQueue.main)
        .map { (accountToken, expiry) -> String in
            self.saveAccountToPreferences(accountToken: accountToken, expiry: expiry)

            return accountToken
        }.eraseToAnyPublisher()
    }

    /// Perform the login and save the account token along with expiry (if available) to the
    /// application preferences.
    func login(with accountToken: String) -> AnyPublisher<(), Error> {
        return rpc.getAccountExpiry(accountToken: accountToken)
            .publisher
            .mapError { .verifyAccount($0) }
            .flatMap { (expiry) -> Future<Date, Error> in
                return Future({ (fulfill) in
                    TunnelManager.shared.setAccount(accountToken: accountToken) { (result) in
                        let result = result
                            .mapError { Error.tunnelConfiguration($0) }
                            .map { expiry }
                        fulfill(result)
                    }
                })
        }
        .receive(on: DispatchQueue.main)
        .map { (expiry) in
            self.saveAccountToPreferences(accountToken: accountToken, expiry: expiry)
        }.eraseToAnyPublisher()
    }

    /// Perform the logout by erasing the account token and expiry from the application preferences.
    func logout() -> AnyPublisher<(), Error> {
        return TunnelManager.shared.unsetAccount()
            .receive(on: DispatchQueue.main)
            .mapError { .tunnelConfiguration($0) }
            .map(self.removeAccountFromPreferences)
            .eraseToAnyPublisher()
    }

    private func saveAccountToPreferences(accountToken: String, expiry: Date) {
        let preferences = UserDefaults.standard

        preferences.set(accountToken, forKey: UserDefaultsKeys.accountToken.rawValue)
        preferences.set(expiry, forKey: UserDefaultsKeys.accountExpiry.rawValue)
    }

    private func removeAccountFromPreferences() {
        let preferences = UserDefaults.standard

        preferences.removeObject(forKey: UserDefaultsKeys.accountToken.rawValue)
        preferences.removeObject(forKey: UserDefaultsKeys.accountExpiry.rawValue)

    }
}

extension Account: AppStorePaymentObserver {

    func startPaymentMonitoring(with paymentManager: AppStorePaymentManager) {
        paymentManager.addPaymentObserver(self)
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager, transaction: SKPaymentTransaction, didFailWithError error: AppStorePaymentManager.Error) {
        // no-op
    }

    func appStorePaymentManager(_ manager: AppStorePaymentManager, transaction: SKPaymentTransaction, didFinishWithResponse response: SendAppStoreReceiptResponse) {
        UserDefaults.standard.set(response.newExpiry,
                                  forKey: UserDefaultsKeys.accountExpiry.rawValue)

        NotificationCenter.default.post(
            name: Self.didUpdateAccountExpiryNotification,
            object: self, userInfo: [Self.newAccountExpiryUserInfoKey: response.newExpiry]
        )
    }
}
