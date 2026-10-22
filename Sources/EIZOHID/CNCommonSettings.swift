import Foundation

/// The four read-only CN preferences exposed in the mode-common menu.
public struct CNCommonSettings: Codable, Equatable, Sendable {
    public let checkResolution: Bool?
    public let appliesICCProfile: Bool?
    public let checkSignalInfoWarning: Bool?
    public let checkVideoCardGammaChangeToMakeItLinear: Bool?

    init(data: Data) throws {
        struct Preference: Decodable {
            let checkResolution: Bool?
            let appliesICCProfile: Bool?
            let agent: Agent?
            struct Agent: Decodable {
                let checkSignalInfoWarning: Bool?
                let checkVideoCardGammaChangeToMakeItLinear: Bool?
            }
        }
        let value = try JSONDecoder().decode(Preference.self, from: data)
        checkResolution = value.checkResolution
        appliesICCProfile = value.appliesICCProfile
        checkSignalInfoWarning = value.agent?.checkSignalInfoWarning
        checkVideoCardGammaChangeToMakeItLinear = value.agent?.checkVideoCardGammaChangeToMakeItLinear
    }
}
