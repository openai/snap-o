actor ADBService {
  private let client: ADBClient

  init(client: ADBClient = ADBClient()) {
    self.client = client
  }

  func exec() -> ADBClient {
    client
  }
}
