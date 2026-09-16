import Darwin
import XCTest
@testable import AgenticSidebar

/// The port is probed and released before the child binds it, so the app has to
/// prove the child owns it before the first request that carries the server
/// password. These tests exercise the check against real sockets.
final class ListenerVerificationTests: XCTestCase {
    func testTheProcessListeningOnAPortIsRecognisedAsItsOwner() async throws {
        let listener = try Self.makeListener()
        defer { Darwin.close(listener.descriptor) }

        XCTAssertTrue(
            LibprocListenerVerifier.listeningPorts(of: getpid()).contains(listener.port),
            "A socket this process is listening on must be visible on its own descriptors"
        )

        let verifier = LibprocListenerVerifier(attempts: 3, delay: .milliseconds(10))
        let ownsPort = await verifier.waitUntilProcessOwnsListeningPort(
            listener.port,
            processIdentifier: getpid()
        )
        XCTAssertTrue(ownsPort)
    }

    /// A port nobody holds must not read as "the child owns it" — otherwise an
    /// impostor's port would pass the check and receive the password.
    func testAPortNobodyListensOnIsNotAccepted() async throws {
        let freePort = try SystemOpenCodePortAllocator().allocate()

        XCTAssertFalse(
            LibprocListenerVerifier.listeningPorts(of: getpid()).contains(freePort),
            "Sanity: the port is free"
        )

        let verifier = LibprocListenerVerifier(attempts: 1, delay: .milliseconds(10))
        let ownsPort = await verifier.waitUntilProcessOwnsListeningPort(
            freePort,
            processIdentifier: getpid()
        )
        XCTAssertFalse(ownsPort)
    }

    /// No pid means no proof, and no proof means the password is not sent.
    func testAMissingProcessIdentifierIsNotOwnership() async {
        let verifier = LibprocListenerVerifier(attempts: 1, delay: .milliseconds(10))

        let ownsPort = await verifier.waitUntilProcessOwnsListeningPort(4242, processIdentifier: nil)
        XCTAssertFalse(ownsPort)

        let ownsPortForDeadPid = await verifier.waitUntilProcessOwnsListeningPort(
            4242,
            processIdentifier: 999_999
        )
        XCTAssertFalse(ownsPortForDeadPid, "A pid that is not running cannot be the listener")
    }

    func testThePortAllocatorHandsOutAPortItIsNotHolding() throws {
        // Whatever the allocator returns, the socket it used to find the number has
        // to be closed already: a port that is still bound cannot be taken by the
        // child, and a probe that leaked the socket would deadlock the start.
        let port = try SystemOpenCodePortAllocator().allocate()

        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse(
            LibprocListenerVerifier.listeningPorts(of: getpid()).contains(port),
            "The probe must release the port for the child to bind"
        )
    }

    private static func makeListener() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ProviderRuntimeError.startupFailure
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw ProviderRuntimeError.startupFailure
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw ProviderRuntimeError.startupFailure
        }

        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }
}
