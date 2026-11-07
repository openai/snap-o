import Darwin
import Foundation

/// Associates console commands with the process serving the verified, still-open gRPC socket.
enum EmulatorSocketOwner {
  static func verify(_ socket: Int32, native: EmulatorNativeConnection) throws {
    guard native.processID > 0, (1024 ... 65535).contains(native.grpcPort),
          (1024 ... 65535).contains(native.clientPort) else { throw failure() }
    let local = try address(socket, peer: false)
    let remote = try address(socket, peer: true)
    try requireConnection(processID: native.processID, localPort: native.grpcPort, remotePort: native.clientPort)
    try requireConnection(processID: native.processID, localPort: remote, remotePort: local)
  }

  private static func address(_ socket: Int32, peer: Bool) throws -> Int {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        peer ? getpeername(socket, $0, &length) : getsockname(socket, $0, &length)
      }
    }
    guard result == 0, address.sin_family == AF_INET,
          address.sin_addr.s_addr == inet_addr("127.0.0.1") else { throw failure() }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private static func requireConnection(processID: Int32, localPort: Int, remotePort: Int) throws {
    let size = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { throw failure() }
    // Allow descriptors opened between the size query and the snapshot. A missing match fails closed.
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
    let bytes = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard bytes > 0 else { throw failure() }
    for descriptor in descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
      where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
      var info = socket_fdinfo()
      let bytes = withUnsafeMutablePointer(to: &info) {
        proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, Int32(MemoryLayout<socket_fdinfo>.size))
      }
      guard bytes == MemoryLayout<socket_fdinfo>.size, info.psi.soi_family == AF_INET,
            info.psi.soi_kind == SOCKINFO_TCP else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      let ip = tcp.tcpsi_ini
      if tcp.tcpsi_state == TSI_S_ESTABLISHED,
         Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ip.insi_lport))) == localPort,
         Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ip.insi_fport))) == remotePort,
         ip.insi_laddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1"),
         ip.insi_faddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1") { return }
    }
    throw failure()
  }

  private static func failure() -> AndroidHostServiceError {
    AndroidHostServiceError(message: "The emulator connection changed. Reopen Live Preview and try again.")
  }
}
