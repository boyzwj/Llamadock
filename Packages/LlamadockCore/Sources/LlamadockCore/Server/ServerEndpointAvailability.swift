import Darwin
import Foundation

public enum ServerEndpointAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

public protocol ServerEndpointChecking: Sendable {
    func check(
        host: String,
        port: UInt16
    ) -> ServerEndpointAvailability
}

public struct SocketServerEndpointChecker: ServerEndpointChecking {
    public init() {}

    public func check(
        host: String,
        port: UInt16
    ) -> ServerEndpointAvailability {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var addresses: UnsafeMutablePointer<addrinfo>?
        let resolutionStatus = getaddrinfo(
            host,
            String(port),
            &hints,
            &addresses
        )
        guard resolutionStatus == 0, let addresses else {
            return .unavailable(
                reason: String(cString: gai_strerror(resolutionStatus))
            )
        }
        defer { freeaddrinfo(addresses) }

        var pointer: UnsafeMutablePointer<addrinfo>? = addresses
        var hasAvailableAddress = false
        var firstError: Int32?
        var isAddressInUse = false

        while let current = pointer {
            let info = current.pointee
            let descriptor = Darwin.socket(
                info.ai_family,
                info.ai_socktype,
                info.ai_protocol
            )
            if descriptor >= 0 {
                let bindStatus = Darwin.bind(
                    descriptor,
                    info.ai_addr,
                    info.ai_addrlen
                )
                let bindError = errno
                Darwin.close(descriptor)

                if bindStatus == 0 {
                    hasAvailableAddress = true
                } else {
                    firstError = firstError ?? bindError
                    isAddressInUse = isAddressInUse
                        || bindError == EADDRINUSE
                }
            } else {
                firstError = firstError ?? errno
            }
            pointer = info.ai_next
        }

        if isAddressInUse {
            return .unavailable(
                reason: "\(host):\(port) is already in use."
            )
        }
        if hasAvailableAddress {
            return .available
        }

        let error = firstError ?? EADDRNOTAVAIL
        return .unavailable(
            reason: String(cString: strerror(error))
        )
    }
}
