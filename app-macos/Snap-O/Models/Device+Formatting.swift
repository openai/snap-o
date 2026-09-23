import Foundation

extension Device {
  /// Prefer the resolved emulator name, then Android properties.
  var displayTitle: String {
    if let displayName, !displayName.isEmpty {
      return displayName
    }
    if let avdName, !avdName.isEmpty {
      return avdName
    }
    if let vendorModel, !vendorModel.isEmpty {
      return vendorModel
    }
    return model
  }
}
