import Foundation

/// A connected device shown in this window's preview picker.
struct LivePreviewDevice: Identifiable, Equatable {
  let id: UUID
  let device: Device
  let display: DisplayInfo?
}
