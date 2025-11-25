import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NetworkInspectorBodySection: View {
  let title: String
  let payload: NetworkInspectorRequestViewModel.BodyPayload
  private let imagePreview: ImagePreview?
  @Binding private var isExpanded: Bool
  @Binding private var usePrettyPrinted: Bool

  init(
    title: String,
    payload: NetworkInspectorRequestViewModel.BodyPayload,
    isExpanded: Binding<Bool>,
    isPrettyPrinted: Binding<Bool>
  ) {
    self.title = title
    self.payload = payload
    self.imagePreview = Self.makeImagePreview(from: payload)
    _isExpanded = isExpanded
    _usePrettyPrinted = isPrettyPrinted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .rotationEffect(isExpanded ? .degrees(90) : .zero)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
              .font(.headline)

            if let metadata = metadataText {
              Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        if let imagePreview {
          InspectorCard {
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 6) {
                Text("Image preview")
                  .font(.subheadline.weight(.semibold))
                if let label = imagePreview.typeLabel {
                  Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(imagePreview.metadata)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              imagePreview.image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: imagePreview.displaySize.width)
                .background(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                )
                .contextMenu {
                  Button("Copy Image") {
                    copyImage(imagePreview)
                  }
                  Button("Save As…") {
                    saveImage(imagePreview)
                  }
                }
            }
          }
          .padding(.top, 8)
        } else {
          InspectorCard {
            InspectorPayloadView(
              rawText: payload.rawText,
              prettyText: payload.prettyPrintedText,
              isLikelyJSON: payload.isLikelyJSON,
              usePrettyPrinted: $usePrettyPrinted,
              isExpandable: false,
              embedControlsInJSON: true
            )
          }
          .padding(.top, 8)
        }
      }
    }
  }

  private var metadataText: String? {
    var parts: [String] = []

    if payload.capturedBytes > 0 {
      parts.append("Captured \(formatBytes(payload.capturedBytes))")
      if let total = payload.totalBytes {
        parts.append("of \(formatBytes(total))")
      }
    } else if let total = payload.totalBytes {
      parts.append("Total \(formatBytes(total))")
    }

    if let truncated = payload.truncatedBytes {
      if truncated > 0 {
        parts.append("(\(formatBytes(truncated)) truncated)")
      } else if truncated == 0, !payload.isPreview {
        parts.append("(complete)")
      }
    } else if payload.isPreview {
      parts.append("(preview)")
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " ")
  }

  private static func makeImagePreview(from payload: NetworkInspectorRequestViewModel.BodyPayload) -> ImagePreview? {
    guard let data = payload.data, let nsImage = NSImage(data: data) else { return nil }
    let pixelSize = nsImage.representations.compactMap { rep -> CGSize? in
      guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
      return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
    }.first ?? nsImage.size

    return ImagePreview(
      image: Image(nsImage: nsImage),
      nsImage: nsImage,
      data: data,
      displaySize: nsImage.size,
      pixelSize: pixelSize,
      byteCount: data.count,
      typeLabel: payload.contentType?.uppercased(),
      contentType: payload.contentType
    )
  }

  private func copyImage(_ preview: ImagePreview) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([preview.nsImage])
  }

  private func saveImage(_ preview: ImagePreview) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    if let type = preview.uniformType {
      panel.allowedContentTypes = [type]
      panel.nameFieldStringValue = "image.\(type.preferredFilenameExtension ?? "")"
    } else {
      panel.nameFieldStringValue = "image"
    }

    if panel.runModal() == .OK, let url = panel.url {
      do {
        try preview.data.write(to: url)
      } catch {
        NSSound.beep()
      }
    }
  }
}

private struct ImagePreview {
  let image: Image
  let nsImage: NSImage
  let data: Data
  let displaySize: CGSize
  let pixelSize: CGSize
  let byteCount: Int
  let typeLabel: String?
  let contentType: String?

  var metadata: String {
    let dimensionText = "\(Int(pixelSize.width))×\(Int(pixelSize.height)) px"
    let sizeText = formatBytes(Int64(byteCount))
    return "\(dimensionText) • \(sizeText)"
  }

  var preferredExtension: String? {
    guard let contentType else { return nil }
    if contentType.hasPrefix("image/png") { return "png" }
    if contentType.hasPrefix("image/jpeg") || contentType.hasPrefix("image/jpg") { return "jpg" }
    if contentType.hasPrefix("image/webp") { return "webp" }
    return nil
  }

  var uniformType: UTType? {
    guard let ext = preferredExtension else { return nil }
    return UTType(filenameExtension: ext)
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}
