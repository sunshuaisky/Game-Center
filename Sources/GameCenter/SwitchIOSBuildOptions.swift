import Foundation

struct S2ArmDeviceTarget: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let productType: String
    let gpuArch: String
    var id: String { productType }
}

struct S2ArmDeviceChoices: Decodable, Sendable {
    let models: [S2ArmDeviceTarget]
}

struct SwitchIOSBuildOptions: Sendable {
    var s2ArmSGrade = true
    var s2ArmDevice: S2ArmDeviceTarget?
    var nxCompatibleOlderDevices = false

    var s2ArmRequest: [String: Any] {
        var request: [String: Any] = ["sgrade": s2ArmSGrade]
        if let device = s2ArmDevice {
            request["target"] = [
                "model": device.name, "productType": device.productType,
                "gpuArch": device.gpuArch
            ]
        }
        return request
    }

    var nxEnvironmentFile: String {
        "DM_PROF_TEX_BC_CPU=\(nxCompatibleOlderDevices ? "1" : "0")\n"
    }
}
