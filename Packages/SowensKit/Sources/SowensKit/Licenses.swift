import Foundation

public enum SowensLicenses {
    public static var text: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
