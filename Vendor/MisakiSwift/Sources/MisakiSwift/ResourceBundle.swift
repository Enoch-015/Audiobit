import Foundation

extension Bundle {
  static var misakiResources: Bundle {
    let packaged = Bundle.main.resourceURL
      .map { $0.appendingPathComponent("DocumentReader_MisakiSwift.bundle") }
      .flatMap(Bundle.init(url:))
    return packaged ?? Bundle.module
  }
}
