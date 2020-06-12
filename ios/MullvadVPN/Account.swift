//
//  Account.swift
//  MullvadVPN
//
//  Created by pronebird on 16/05/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

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

    func loginWithNewAccount(completionHandler: @escaping (Result<(String, Date), Error>) -> Void) {
        let urlSessionTask = rpc.createAccount().dataTask { (rpcResult) in
            DispatchQueue.main.async {
                switch rpcResult {
                case .success(let newAccountToken):
                    let expiry = Date()
                    self.setupTunnel(accountToken: newAccountToken, expiry: expiry) { (result) in
                        completionHandler(result.map { (newAccountToken, expiry) })
                    }

                case .failure(let error):
                    completionHandler(.failure(.createAccount(error)))
                }
            }
        }

        urlSessionTask?.resume()
    }

    /// Perform the login and save the account token along with expiry (if available) to the
    /// application preferences.
    func login(with accountToken: String, completionHandler: @escaping (Result<Date, Error>) -> Void) {
        let urlSessionTask = rpc.getAccountExpiry(accountToken: accountToken)
            .dataTask { (rpcResult) in
                DispatchQueue.main.async {
                    switch rpcResult {
                    case .success(let expiry):
                        self.setupTunnel(accountToken: accountToken, expiry: expiry) { (result) in
                            completionHandler(result.map { expiry })
                        }

                    case .failure(let error):
                        completionHandler(.failure(.verifyAccount(error)))
                    }
                }
        }

        urlSessionTask?.resume()
    }

    /// Perform the logout by erasing the account token and expiry from the application preferences.
    func logout(completionHandler: @escaping (Result<(), Error>) -> Void) {
        TunnelManager.shared.unsetAccount { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.removeAccountFromPreferences()

                    completionHandler(.success(()))

                case .failure(let error):
                    completionHandler(.failure(.tunnelConfiguration(error)))
                }
            }
        }
    }

    private func setupTunnel(accountToken: String, expiry: Date, completionHandler: @escaping (Result<(), Error>) -> Void) {
          TunnelManager.shared.setAccount(accountToken: accountToken) { (managerResult) in
              DispatchQueue.main.async {
                  switch managerResult {
                  case .success:
                      self.saveAccountToPreferences(
                          accountToken: accountToken,
                          expiry: expiry
                      )
                      completionHandler(.success(()))

                  case .failure(let error):
                      completionHandler(.failure(.tunnelConfiguration(error)))
                  }
              }
          }
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
