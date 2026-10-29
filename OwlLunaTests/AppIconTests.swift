import XCTest
@testable import OwlLuna

@MainActor
final class AppIconTests: XCTestCase {
    /// Each alternate is declared in the generated Info.plist, or the system refuses to switch to it.
    func testEveryAlternateIconIsDeclared() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: Device.isPhone ? "CFBundleIcons" : "CFBundleIcons~ipad") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        let names = AppIconChoice.allCases.compactMap(\.iconName)
        XCTAssertEqual(names.count, AppIconChoice.allCases.count - 1)
        for name in names {
            XCTAssertNotNil(alternates[name], "\(name) isn't in CFBundleAlternateIcons")
        }
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
    }

    /// Settings shows a preview of each icon, drawn for light and dark.
    func testEveryPreviewLoads() {
        for choice in AppIconChoice.allCases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                XCTAssertNotNil(UIImage(named: choice.previewName, in: .main, compatibleWith: traits), "\(choice.previewName) \(style.rawValue)")
            }
        }
    }

    func testChoiceFollowsTheAlternateIconName() {
        XCTAssertEqual(AppIconChoice(iconName: nil), .cobalt)
        XCTAssertEqual(AppIconChoice(iconName: "AppIcon-Moss"), .moss)
        XCTAssertEqual(AppIconChoice(iconName: "AppIcon-Unknown"), .cobalt)
        for choice in AppIconChoice.allCases {
            XCTAssertEqual(AppIconChoice(iconName: choice.iconName), choice)
        }
    }
}
