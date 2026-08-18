import AppKit
import Observation
import SwiftUI

struct AppInspectorPicker: View {
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
        AppInspectorIcon(
          app: model.selectedInspectorApp,
          size: Metrics.iconSize,
          statusSize: Metrics.statusSize
        )

        HStack(spacing: 6) {
          AppInspectorPickerText(
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
      AppInspectorPickerPopover(model: model) {
        isPresented = false
      }
    }
    .help("Select an app")
  }

  private var selectedTitle: String {
    guard let app = model.selectedInspectorApp else {
      return model.inspectorApps.isEmpty ? "No Apps Found" : "Select an App"
    }

    return app.name
  }

  private var deviceTitle: String {
    guard let title = model.selectedInspectorApp?.deviceDisplayTitle,
          !title.isEmpty
    else {
      return model.inspectorApps.isEmpty ? "No devices detected" : "Choose a device"
    }
    return title
  }
}

struct AppInspectorViewPicker: View {
  @Bindable var model: NetworkInspectorHostModel

  var body: some View {
    if let app = model.selectedInspectorApp, app.inspectors.count > 1 {
      HStack(spacing: 0) {
        ForEach(app.inspectors) { option in
          Button {
            model.selectInspector(app, option: option)
          } label: {
            Label(option.kind.title, systemImage: option.kind.systemImage)
              .labelStyle(.iconOnly)
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(model.selectedInspector?.kind == option.kind ? Color.accentColor : Color.primary)
              .frame(width: 34, height: 32)
          }
          .help(option.kind.title)
        }
      }
      .snapOToolbarGroupStyle()
      .accessibilityLabel("Inspector")
    }
  }
}

private struct AppInspectorPickerPopover: View {
  private enum Metrics {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 480
    static let nonTextWidth: CGFloat = 103
  }

  @Bindable var model: NetworkInspectorHostModel
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.inspectorApps.isEmpty {
        Text("No Apps Found")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.inspectorApps) { app in
              AppInspectorPickerAppRow(
                app: app,
                isSelected: model.selectedInspector?.appId == app.id,
                selectApp: {
                  model.selectApp(app)
                  dismiss()
                },
                selectInspector: { option in
                  model.selectInspector(app, option: option)
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
    let contentWidth = model.inspectorApps.map { app in
      max(
        textWidth(app.name, font: appFont),
        textWidth(app.deviceDisplayTitle, font: deviceFont)
      ) + Metrics.nonTextWidth + CGFloat(app.inspectors.count) * AppInspectorPickerAppRow.shortcutWidth
    }.max() ?? Metrics.minimumWidth

    return min(max(ceil(contentWidth), Metrics.minimumWidth), Metrics.maximumWidth)
  }

  private func textWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }
}

private struct AppInspectorPickerAppRow: View {
  static let shortcutWidth: CGFloat = 28

  let app: InspectableApp
  let isSelected: Bool
  let selectApp: () -> Void
  let selectInspector: (AppInspectorOption) -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: selectApp) {
      HStack(spacing: 10) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 15)
          .opacity(isSelected ? 1 : 0)

        AppInspectorIcon(app: app, size: 32, statusSize: 0)

        AppInspectorPickerText(
          appName: app.name,
          deviceName: app.deviceDisplayTitle
        )

        Spacer(minLength: CGFloat(app.inspectors.count) * Self.shortcutWidth + 8)
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
    .disabled(app.inspectors.isEmpty)
    .help(app.packageName)
    .overlay(alignment: .trailing) {
      HStack(spacing: 0) {
        ForEach(app.inspectors) { option in
          AppInspectorPickerShortcut(
            option: option,
            appName: app.name
          ) {
            selectInspector(option)
          }
        }
      }
      .padding(.trailing, 8)
    }
    .onHover { isHovering = $0 }
  }
}

private struct AppInspectorPickerShortcut: View {
  let option: AppInspectorOption
  let appName: String
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      Label(option.kind.title, systemImage: option.kind.systemImage)
        .labelStyle(.iconOnly)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: AppInspectorPickerAppRow.shortcutWidth, height: 32)
        .contentShape(Rectangle())
        .background {
          if isHovering {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(Color.primary.opacity(0.08))
          }
        }
    }
    .buttonStyle(.plain)
    .help("Open \(option.kind.title)")
    .accessibilityLabel("Open \(option.kind.title) for \(appName)")
    .onHover { isHovering = $0 }
  }
}

private struct AppInspectorPickerText: View {
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

private struct AppInspectorIcon: View {
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

private extension AppInspectorKind {
  var title: String {
    switch self {
    case .network: "Network"
    case .tweaks: "Tweaks"
    }
  }

  var systemImage: String {
    switch self {
    case .network: "network"
    case .tweaks: "slider.horizontal.3"
    }
  }
}
