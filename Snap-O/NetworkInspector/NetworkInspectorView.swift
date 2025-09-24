import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore

  var body: some View {
    NavigationView {
      List {
        Section("Servers") {
          if store.servers.isEmpty {
            Text("No active servers")
              .foregroundStyle(.secondary)
          } else {
            ForEach(store.servers) { server in
              VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                  .font(.headline)
                if let hello = server.helloSummary {
                  Text(hello)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        Section("Events") {
          if store.events.isEmpty {
            Text("No events yet")
              .foregroundStyle(.secondary)
          } else {
            ForEach(store.events) { event in
              VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                  .font(.subheadline)
                if let details = event.detail {
                  Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Network Inspector")
    }
  }
}
