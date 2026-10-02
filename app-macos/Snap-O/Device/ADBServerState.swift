enum ADBServerState: Equatable {
  case connecting
  case starting
  case online
  case unavailable(String)
}
