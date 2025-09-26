import Foundation

extension Device {
  // Primary display name prefers vendor model when available.
  var displayTitle: String {
    // Prefer emulator AVD name when available
    if let avdName, !avdName.isEmpty {
      return avdName
    }
    if let vendorModel, !vendorModel.isEmpty {
      return vendorModel
    }
    return model
  }
}
