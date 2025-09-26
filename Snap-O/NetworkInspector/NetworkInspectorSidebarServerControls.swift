import SwiftUI

struct NetworkInspectorSidebarServerControls: View {
  @ObservedObject var store: NetworkInspectorStore
  @Binding var selectedServerID: NetworkInspectorServer.ID?
  @Binding var isServerPickerPresented: Bool
  let selectedServer: NetworkInspectorServerViewModel?
  let replacementServerCandidate: NetworkInspectorServerViewModel?

  var body: some View {
    VStack(spacing: 8) {
      serverPicker

      if let candidate = replacementServerCandidate {
        replacementServerButton(for: candidate)
      }
    }
  }

  private var serverPicker: some View {
    Group {
      if store.servers.isEmpty {
        HStack {
          Text("No Apps Found")
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
      } else {
        Button {
          isServerPickerPresented.toggle()
        } label: {
          HStack(spacing: 12) {
            if let server = selectedServer {
              serverRowContent(for: server)
            } else {
              placeholderRowContent(title: "Select an App", subtitle: "")
            }

            Spacer()

            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 10)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isServerPickerPresented, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 0) {
            serversPopover
          }
          .padding(8)
        }
      }
    }
  }

  private func replacementServerButton(for server: NetworkInspectorServerViewModel) -> some View {
    Button {
      selectedServerID = server.id
      isServerPickerPresented = false
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.headline.weight(.semibold))
          .foregroundStyle(Color.white)

        VStack(alignment: .leading, spacing: 2) {
          Text("New process available")
            .font(.headline)
            .foregroundStyle(Color.white)
            .lineLimit(1)

          if let pid = server.pid {
            Text("PID \(pid)")
              .font(.caption)
              .foregroundStyle(Color.white.opacity(0.85))
          }
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.white.opacity(0.9))
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 56)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.orange)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func serversPopoverRow(for server: NetworkInspectorServerViewModel) -> some View {
    serverRowContent(for: server)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .background(
        (selectedServerID == server.id ? Color.accentColor.opacity(0.12) : Color.clear)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      )
      .contentShape(Rectangle())
  }

  private var serversPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(store.servers) { server in
        Button {
          selectedServerID = server.id
          isServerPickerPresented = false
        } label: {
          serversPopoverRow(for: server)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
      }
    }
    .padding(.vertical, 8)
    .frame(minWidth: 280)
  }

  @ViewBuilder
  private func serverRowContent(for server: NetworkInspectorServerViewModel) -> some View {
    serverRow(title: server.displayName, subtitle: server.deviceDisplayTitle, isConnected: server.isConnected)
  }

  private func placeholderRowContent(title: String, subtitle: String) -> some View {
    serverRow(title: title, subtitle: subtitle, isConnected: true)
  }

  private func serverRow(title: String, subtitle: String, isConnected: Bool) -> some View {
    HStack(spacing: 12) {
      appIconView(isConnected: isConnected)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize(horizontal: false, vertical: true)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .opacity(isConnected ? 1 : 0.75)
  }

  private func appIconView(isConnected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(isConnected ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05))
      .overlay(
        Image(systemName: "app.fill")
          .font(.subheadline)
          .foregroundStyle(isConnected ? Color.secondary : Color.secondary.opacity(0.35))
          .saturation(isConnected ? 1 : 0)
      )
      .overlay(alignment: .bottomTrailing) {
        if !isConnected {
          Image(systemName: "link.slash")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .padding(4)
            .background(Circle().fill(Color.secondary.opacity(0.2)))
            .offset(x: 4, y: 4)
        }
      }
      .saturation(isConnected ? 1 : 0)
      .opacity(isConnected ? 1 : 0.6)
      .frame(width: 32, height: 32)
  }
}
