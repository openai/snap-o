import AppKit
import Observation
import SwiftUI

struct NetworkInspectorServerPicker: View {
  private enum Metrics {
    static let iconSize: CGFloat = 32
    static let statusSize: CGFloat = 8
    static let height: CGFloat = 48
  }

  @Bindable var model: NetworkInspectorHostModel
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 12) {
        if let server = model.selectedServer {
          NetworkInspectorServerIcon(
            server,
            size: Metrics.iconSize,
            statusSize: Metrics.statusSize
          )
        } else {
          NetworkInspectorServerIcon(
            server: nil,
            size: Metrics.iconSize,
            statusSize: Metrics.statusSize
          )
        }

        HStack(spacing: 6) {
          NetworkInspectorServerText(
            appName: model.selectedServer?.displayName ?? emptyTitle,
            deviceName: deviceTitle
          )

          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isPresented ? 180 : 0))
        }
      }
      .frame(height: Metrics.height)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      NetworkInspectorServerPickerPopover(model: model) {
        model.selectServer($0)
        isPresented = false
      }
    }
    .help("Select an app to inspect")
  }

  private var emptyTitle: String {
    model.servers.isEmpty ? "No Apps Found" : "Select an App"
  }

  private var deviceTitle: String {
    guard let title = model.selectedServer?.deviceDisplayTitle,
          !title.isEmpty
    else {
      return model.servers.isEmpty ? "No devices detected" : "Choose a device"
    }
    return title
  }
}

private struct NetworkInspectorServerPickerPopover: View {
  @Bindable var model: NetworkInspectorHostModel
  let selectServer: (NetworkInspectorServer) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Detected servers")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

      if model.servers.isEmpty {
        Text("No Apps Found")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.bottom, 14)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.servers, id: \.server) { server in
              NetworkInspectorServerPickerRow(server: server) {
                selectServer(server)
              }
            }
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 6)
        }
        .frame(maxHeight: 320)
      }
    }
    .frame(width: 320)
  }
}

private struct NetworkInspectorServerPickerRow: View {
  let server: NetworkInspectorServer
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 12) {
        NetworkInspectorServerIcon(server, size: 32, statusSize: 8)
        NetworkInspectorServerText(
          appName: server.displayName,
          deviceName: server.deviceDisplayTitle
        )
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      .contentShape(Rectangle())
      .background {
        if isHovering {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.07))
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

private struct NetworkInspectorServerText: View {
  let appName: String
  let deviceName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(appName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text(deviceName)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

private struct NetworkInspectorServerIcon: View {
  let server: NetworkInspectorServer?
  let size: CGFloat
  let statusSize: CGFloat

  init(
    _ server: NetworkInspectorServer,
    size: CGFloat,
    statusSize: CGFloat
  ) {
    self.server = server
    self.size = size
    self.statusSize = statusSize
  }

  init(
    server: NetworkInspectorServer?,
    size: CGFloat,
    statusSize: CGFloat
  ) {
    self.server = server
    self.size = size
    self.statusSize = statusSize
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      icon

      if let server {
        Circle()
          .fill(server.isConnected ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
          .frame(width: statusSize, height: statusSize)
          .overlay {
            Circle()
              .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
          }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var icon: some View {
    if let base64 = server?.appIconBase64,
       let data = Data(base64Encoded: base64),
       let image = NSImage(data: data) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    } else {
      Circle()
        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        .frame(width: size, height: size)
    }
  }
}
