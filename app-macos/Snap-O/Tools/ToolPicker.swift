import AppKit
import Observation
import SwiftUI

struct AppToolPicker: View {
  private enum Metrics {
    static let iconSize: CGFloat = 32
    static let statusSize: CGFloat = 8
    static let height: CGFloat = 48
  }

  @Bindable var model: ToolHostModel
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 12) {
        AppToolIcon(
          app: model.selectedToolApp,
          size: Metrics.iconSize,
          statusSize: model.isWaiting || model.compatibilityExplanation != nil ? 0 : Metrics.statusSize
        )

        HStack(spacing: 6) {
          AppToolPickerText(
            appName: selectedTitle,
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
      AppToolPickerPopover(model: model) {
        isPresented = false
      }
    }
    .help("Select an app")
  }

  private var selectedTitle: String {
    guard let app = model.selectedToolApp else {
      return model.toolApps.isEmpty ? "No Apps Found" : "Select an App"
    }

    return app.name
  }

  private var deviceTitle: String {
    guard let title = model.selectedToolApp?.deviceDisplayTitle,
          !title.isEmpty
    else {
      return model.toolApps.isEmpty ? "No devices detected" : "Choose a device"
    }
    return title
  }
}

struct AppToolReconnectButton: View {
  @Bindable var model: ToolHostModel
  @Environment(\.colorScheme)
  private var colorScheme

  private var backgroundColor: Color {
    colorScheme == .dark
      ? Color(red: 184 / 255, green: 106 / 255, blue: 0)
      : Color(red: 246 / 255, green: 158 / 255, blue: 0)
  }

  var body: some View {
    if model.replacementApp != nil {
      Button {
        model.reconnectToNewProcess()
      } label: {
        Label("New process", systemImage: "arrow.clockwise")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .frame(height: SnapOToolbarStyle.singleControlSize)
          .background(backgroundColor, in: Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .fixedSize()
      .help("Reconnect to the new process")
      .accessibilityLabel("Reconnect to new process")
    }
  }
}

struct AppToolViewPicker: View {
  @Bindable var model: ToolHostModel

  var body: some View {
    if let app = model.selectedToolApp,
       app.tools.count > 1 || (model.selectedTool == nil && !app.tools.isEmpty) {
      HStack(spacing: 0) {
        ForEach(app.tools) { option in
          Button {
            model.selectTool(app, option: option)
          } label: {
            Label {
              Text(option.displayName)
            } icon: {
              ToolToolIcon(option: option)
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(model.preferredPluginID == option.kind ? Color.accentColor : Color.primary)
            .frame(width: 34, height: 32)
          }
          .help(option.displayName + (option.compatibility.isUnsupported ? ": Unsupported tool" : ""))
        }
      }
      .snapOToolbarGroupStyle()
      .accessibilityLabel("Tool")
    }
  }
}

private struct AppToolPickerPopover: View {
  private enum Metrics {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 480
    static let nonTextWidth: CGFloat = 103
  }

  @Bindable var model: ToolHostModel
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.toolApps.isEmpty {
        Text("No Apps Found")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.toolApps) { app in
              AppToolPickerAppRow(
                app: app,
                isSelected: model.selectedToolApp?.id == app.id,
                selectApp: {
                  model.selectApp(app)
                  dismiss()
                },
                selectTool: { option in
                  model.selectTool(app, option: option)
                  dismiss()
                }
              )
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(width: preferredWidth)
  }

  private var preferredWidth: CGFloat {
    let appFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    let deviceFont = NSFont.systemFont(ofSize: 12)
    let contentWidth = model.toolApps.map { app in
      max(
        textWidth(app.name, font: appFont),
        textWidth(app.deviceDisplayTitle, font: deviceFont)
      ) + Metrics.nonTextWidth + CGFloat(app.tools.count) * AppToolPickerAppRow.shortcutWidth
    }.max() ?? Metrics.minimumWidth

    return min(max(ceil(contentWidth), Metrics.minimumWidth), Metrics.maximumWidth)
  }

  private func textWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }
}

private struct AppToolPickerAppRow: View {
  static let shortcutWidth: CGFloat = 28

  let app: InspectableApp
  let isSelected: Bool
  let selectApp: () -> Void
  let selectTool: (AppToolOption) -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: selectApp) {
      HStack(spacing: 10) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 15)
          .opacity(isSelected ? 1 : 0)

        AppToolIcon(app: app, size: 32, statusSize: 0)

        AppToolPickerText(
          appName: app.name,
          deviceName: app
            .deviceDisplayTitle + (app.tools.contains { $0.compatibility.isUnsupported } ? " · Unsupported tool" : "")
        )

        Spacer(minLength: CGFloat(app.tools.count) * Self.shortcutWidth + 8)
      }
      .padding(.horizontal, 8)
      .frame(height: 52)
      .contentShape(Rectangle())
      .background {
        if isHovering || isSelected {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.08 : 0.05))
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(app.tools.isEmpty)
    .help(app.packageName ?? app.processName ?? app.name)
    .overlay(alignment: .trailing) {
      HStack(spacing: 0) {
        ForEach(app.tools) { option in
          AppToolPickerShortcut(
            option: option,
            appName: app.name
          ) {
            selectTool(option)
          }
        }
      }
      .padding(.trailing, 8)
    }
    .onHover { isHovering = $0 }
  }
}

private struct AppToolPickerShortcut: View {
  let option: AppToolOption
  let appName: String
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      Label {
        Text(option.displayName)
      } icon: {
        ToolToolIcon(option: option)
      }
      .labelStyle(.iconOnly)
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .frame(width: AppToolPickerAppRow.shortcutWidth, height: 32)
      .contentShape(Rectangle())
      .background {
        if isHovering {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.08))
        }
      }
    }
    .buttonStyle(.plain)
    .help(option.compatibility.isUnsupported ? "\(option.displayName): Unsupported tool" : "Open \(option.displayName)")
    .accessibilityLabel("Open \(option.displayName) for \(appName)\(option.compatibility.isUnsupported ? ", unsupported tool" : "")")
    .onHover { isHovering = $0 }
  }
}

private struct ToolToolIcon: View {
  let option: AppToolOption

  var body: some View {
    if option.compatibility.isUnsupported {
      Image(systemName: "exclamationmark.triangle.fill")
    } else if let encoded = option.iconBase64, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
    } else if option.compatibility == .unknown {
      ProgressView().progressViewStyle(.circular).controlSize(.small).frame(width: 16, height: 16)
    } else if option.compatibility == .metadataUnavailable {
      Image(systemName: "wifi.exclamationmark")
    } else {
      Image(systemName: "wrench")
    }
  }
}

private struct AppToolPickerText: View {
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

private struct AppToolIcon: View {
  let app: InspectableApp?
  let size: CGFloat
  let statusSize: CGFloat

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      icon

      if app != nil, statusSize > 0 {
        Circle()
          .fill(Color(nsColor: .systemGreen))
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
    if let base64 = app?.appIconBase64,
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
