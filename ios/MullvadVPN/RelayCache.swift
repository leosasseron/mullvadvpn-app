//
//  RelayCache.swift
//  MullvadVPN
//
//  Created by pronebird on 05/06/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Foundation
import Combine
import os

/// Error emitted by read and write functions
enum RelayCacheError: ChainedError {
    case defaultLocationNotFound
    case read(Error)
    case write(Error)
    case encode(Error)
    case decode(Error)
    case rpc(MullvadRpc.Error)

    var errorDescription: String? {
        switch self {
        case .encode:
            return "Encoding error"
        case .decode:
            return "Decoding error"
        case .defaultLocationNotFound:
            return "Default location not found"
        case .read:
            return "Read error"
        case .write:
            return "Write error"
        case .rpc:
            return "RPC error"
        }
    }
}

class RelayCache {
    /// Mullvad Rpc client
    private let rpc: MullvadRpc

    /// The cache location used by the class instance
    private let cacheFileURL: URL

    /// Thread synchronization
    private let operationLock = NSLock()
    private let operationQueue = OperationQueue()
    private var lastOperation: Operation?

    /// The default cache file location
    static var defaultCacheFileURL: URL? {
        let appGroupIdentifier = ApplicationConfiguration.securityGroupIdentifier
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)

        return containerURL.flatMap { URL(fileURLWithPath: "relays.json", relativeTo: $0) }
    }

    init(cacheFileURL: URL, networkSession: URLSession) {
        rpc = MullvadRpc(session: networkSession)
        self.cacheFileURL = cacheFileURL
    }

    class func withDefaultLocation(networkSession: URLSession) -> Result<RelayCache, RelayCacheError> {
        if let cacheFileURL = defaultCacheFileURL {
            return .success(RelayCache(cacheFileURL: cacheFileURL, networkSession: networkSession))
        } else {
            return .failure(.defaultLocationNotFound)
        }
    }

    class func withDefaultLocationAndEphemeralSession() -> Result<RelayCache, RelayCacheError> {
        return withDefaultLocation(networkSession: URLSession(configuration: .ephemeral))
    }

    /// Read the relay cache and update it from remote if needed.
    func read(completionHandler: @escaping (Result<CachedRelayList, RelayCacheError>) -> Void) {
        let operation = AsyncBlockOutputOperation { (finish) in
            self._read(completionHandler: finish)
        }

        operation.completionBlock = {
            if let output = operation.output {
                completionHandler(output)
            }
        }

        addExclusiveOperation(operation)
    }

    private func _read(completionHandler: @escaping (Result<CachedRelayList, RelayCacheError>) -> Void) {
        let downloadAndSaveRelays = { (_ finish: @escaping (Result<CachedRelayList, RelayCacheError>) -> Void) in
            self.downloadRelays { (result) in
                let result = result.flatMap(self.saveRelays)

                if case .failure(let error) = result {
                    os_log(.error, "%{public}s",
                           error.displayChain(message: "Failed to update the relays"))
                }

                finish(result)
            }
        }

        switch Self.read(cacheFileURL: cacheFileURL) {
        case .success(let cachedRelayList):
            if cachedRelayList.needsUpdate() {
                downloadAndSaveRelays { (result) in
                    let result = result.flatMapError { (error) -> Result<CachedRelayList, RelayCacheError> in
                        // Return cached relay list in case of failure
                        return .success(cachedRelayList)
                    }
                    completionHandler(result)
                }
            } else {
                completionHandler(.success(cachedRelayList))
            }

        case .failure(let readError):
            os_log(.error, "%{public}s", readError.displayChain(message: "Failed to read the relay cache"))

            switch readError {
            case .read(let error as CocoaError) where error.code == .fileReadNoSuchFile:
                os_log(.error, "Relay cache file does not exist. Initiating the download.")

                // Download relay list when unable to read the cache file
                downloadAndSaveRelays(completionHandler)

            case .decode:
                os_log(.error, "Failed to decode the relay cache. Initiating download.")

                // Download relay list when unable to decode the cached data
                downloadAndSaveRelays(completionHandler)

            default:
                completionHandler(.failure(readError))
            }
        }
    }

    private func addExclusiveOperation(_ operation: Operation) {
        operationLock.withCriticalBlock {
            if let lastOperation = lastOperation {
                operation.addDependency(lastOperation)
            }
            lastOperation = operation
            operationQueue.addOperation(operation)
        }
    }

    private func downloadRelays(completionHandler: @escaping (Result<RelayList, RelayCacheError>) -> Void) {
        let urlSessionTask = rpc.getRelayList().dataTask { (result) in
            let result = result
                .map(Self.filterRelayList)
                .mapError { RelayCacheError.rpc($0) }

            completionHandler(result)
        }

        urlSessionTask?.resume()
    }

    private func saveRelays(relayList: RelayList) -> Result<CachedRelayList, RelayCacheError> {
        let cachedRelayList = CachedRelayList(relayList: relayList, updatedAt: Date())

        return Self.write(cacheFileURL: cacheFileURL, record: cachedRelayList)
            .map { cachedRelayList }
    }

    /// Filters the given `RelayList` removing empty leaf nodes, relays without Wireguard tunnels or
    /// Wireguard tunnels without any available ports.
    private class func filterRelayList(_ relayList: RelayList) -> RelayList {
        let filteredCountries = relayList.countries
            .map { (country) -> RelayList.Country in
                var filteredCountry = country

                filteredCountry.cities = country.cities.map { (city) -> RelayList.City in
                    var filteredCity = city

                    filteredCity.relays = city.relays
                        .map { (relay) -> RelayList.Relay in
                            var filteredRelay = relay

                            // filter out tunnels without ports
                            filteredRelay.tunnels?.wireguard = relay.tunnels?.wireguard?
                                .filter { !$0.portRanges.isEmpty }

                            return filteredRelay
                    }.filter { $0.tunnels?.wireguard.flatMap { !$0.isEmpty } ?? false }

                    return filteredCity
                }.filter { !$0.relays.isEmpty }

                return filteredCountry
        }.filter { !$0.cities.isEmpty }

        return RelayList(countries: filteredCountries)
    }
    /// Safely read the cache file from disk using file coordinator
    private class func read(cacheFileURL: URL) -> Result<CachedRelayList, RelayCacheError> {
        var result: Result<CachedRelayList, RelayCacheError>?
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)

        let accessor = { (fileURLForReading: URL) -> Void in
            // Decode data from disk
            result = Result { try Data(contentsOf: fileURLForReading) }
                .mapError { RelayCacheError.read($0) }
                .flatMap { (data) in
                    Result { try JSONDecoder().decode(CachedRelayList.self, from: data) }
                        .mapError { RelayCacheError.decode($0) }
                }
        }

        var error: NSError?
        fileCoordinator.coordinate(readingItemAt: cacheFileURL,
                                   options: [.withoutChanges],
                                   error: &error,
                                   byAccessor: accessor)

        if let error = error {
            result = .failure(.read(error))
        }

        return result!
    }

    /// Safely write the cache file on disk using file coordinator
    private class func write(cacheFileURL: URL, record: CachedRelayList) -> Result<(), RelayCacheError> {
        var result: Result<(), RelayCacheError>?
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)

        let accessor = { (fileURLForWriting: URL) -> Void in
            result = Result { try JSONEncoder().encode(record) }
                .mapError { RelayCacheError.encode($0) }
                .flatMap { (data) in
                    Result { try data.write(to: fileURLForWriting) }
                        .mapError { RelayCacheError.write($0) }
                }
        }

        var error: NSError?
        fileCoordinator.coordinate(writingItemAt: cacheFileURL,
                                   options: [.forReplacing],
                                   error: &error,
                                   byAccessor: accessor)

        if let error = error {
            result = .failure(.write(error))
        }

        return result!
    }
}

/// A struct that represents the relay cache on disk
struct CachedRelayList: Codable {
    /// The relay list stored within the cache entry
    var relayList: RelayList

    /// The date when this cache was last updated
    var updatedAt: Date
}

private extension CachedRelayList {
    /// Returns true if it's time to refresh the relay list cache
    func needsUpdate() -> Bool {
        let now = Date()
        guard let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: updatedAt) else {
            return false
        }
        return now >= nextUpdate
    }
}
