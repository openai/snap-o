import Foundation

extension Device {
  var readableTitle: String {
    if androidVersion != "?" {
      "\(model) • Android \(androidVersion)"
    } else {
      "\(model) • \(id)"
    }
  }
}
