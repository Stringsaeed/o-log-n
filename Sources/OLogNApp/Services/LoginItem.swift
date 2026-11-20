import Foundation
import ServiceManagement

enum LoginItem {
    @MainActor
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    @MainActor
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func isBenign(_ error: Error, enabling: Bool) -> Bool {
        let ns = error as NSError
        if enabling, ns.code == Int(kSMErrorAlreadyRegistered) { return true }
        if !enabling, ns.code == Int(kSMErrorJobNotFound) { return true }
        return false
    }
}
