//
//  PacketTunnelIpc.swift
//  MullvadVPN
//
//  Created by pronebird on 01/11/2019.
//  Copyright © 2019 Mullvad VPN AB. All rights reserved.
//

import Combine
import Foundation
import NetworkExtension

/// A enum describing the kinds of requests that `PacketTunnelProvider` handles
enum PacketTunnelRequest: Int, Codable {
    /// Request the tunnel to reload the configuration
    case reloadConfiguration

    /// Request the tunnel to return the connection information
    case tunnelInformation
}

/// A struct that holds the basic information regarding the tunnel connection
struct TunnelConnectionInfo: Codable, Equatable {
    let ipv4Relay: IPv4Endpoint
    let ipv6Relay: IPv6Endpoint?
    let hostname: String
    let location: Location
}

extension TunnelConnectionInfo: CustomDebugStringConvertible {
    var debugDescription: String {
        return "{ ipv4Relay: \(String(reflecting: ipv4Relay)), " +
               "ipv6Relay: \(String(reflecting: ipv6Relay)), " +
               "hostname: \(String(reflecting: hostname))," +
               "location: \(String(reflecting: location)) }"
    }
}

enum PacketTunnelIpcHandler {}

extension PacketTunnelIpcHandler {

    enum Error: ChainedError {
        /// A failure to encode the request
        case encoding(Swift.Error)

        /// A failure to decode the response
        case decoding(Swift.Error)

        /// A failure to process the request
        case processing(Swift.Error)
    }


    static func decodeRequest(messageData: Data) -> AnyPublisher<PacketTunnelRequest, Error> {
        return Just(messageData)
            .setFailureType(to: Error.self)
            .decode(type: PacketTunnelRequest.self, decoder: JSONDecoder())
            .mapError { .decoding($0) }
            .eraseToAnyPublisher()
    }

    static func encodeResponse<T>(response: T) -> AnyPublisher<Data, Error> where T: Encodable {
        return Just(response)
            .setFailureType(to: Error.self)
            .encode(encoder: JSONEncoder())
            .mapError { .encoding($0) }
            .eraseToAnyPublisher()
    }
}

class PacketTunnelIpc {

    enum Error: ChainedError {
        /// A failure to encode the request
        case encoding(Swift.Error)

        /// A failure to decode the response
        case decoding(Swift.Error)

        /// A failure to send the IPC request
        case send(Swift.Error)

        /// A failure that's raised when the IPC response does not contain any data however the decoder
        /// expected to receive data for decoding
        case nilResponse

        var errorDescription: String? {
            switch self {
            case .encoding:
                return "Encoding failure"
            case .decoding:
                return "Decoding failure"
            case .send:
                return "Submission failure"
            case .nilResponse:
                return "Unexpected nil response from the tunnel"
            }
        }
    }

    let session: VPNTunnelProviderSessionProtocol

    init(session: VPNTunnelProviderSessionProtocol) {
        self.session = session
    }

    func reloadConfiguration() -> AnyPublisher<(), Error> {
        return send(message: .reloadConfiguration)
    }

    func getTunnelInformation() -> AnyPublisher<TunnelConnectionInfo, Error> {
        return send(message: .tunnelInformation)
    }

    private func send(message: PacketTunnelRequest) -> AnyPublisher<(), Error> {
        return sendWithoutDecoding(message: message)
            .map { _ in () }.eraseToAnyPublisher()
    }

    private func send<T>(message: PacketTunnelRequest) -> AnyPublisher<T, Error> where T: Decodable {
        return sendWithoutDecoding(message: message)
            .replaceNil(with: .nilResponse)
            .decode(type: T.self, decoder: JSONDecoder())
            .mapError { Error.decoding($0) }
            .eraseToAnyPublisher()
    }

    private func sendWithoutDecoding(message: PacketTunnelRequest) -> AnyPublisher<Data?, Error> {
        return Just(message)
            .setFailureType(to: Error.self)
            .encode(encoder: JSONEncoder())
            .mapError { Error.encoding($0) }
            .flatMap(self.sendProviderMessage)
            .mapError { .send($0) }
            .eraseToAnyPublisher()
    }

    private func sendProviderMessage(_ messageData: Data) -> Future<Data?, Swift.Error> {
        return Future { (fulfill) in
            do {
                try self.session.sendProviderMessage(messageData, responseHandler: { (response) in
                    fulfill(.success(response))
                })
            } catch {
                fulfill(.failure(error))
            }
        }
    }

}
