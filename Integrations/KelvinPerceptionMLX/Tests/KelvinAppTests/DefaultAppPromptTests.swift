import XCTest
import UniformTypeIdentifiers
import KelvinCore
@testable import KelvinApp

/// Which content types Kelvin offers to become the default for.
///
/// **Nothing here calls `claim` or `relinquish`.** Those change a Launch Services setting for the whole
/// login session, and a test suite that reassigns the machine's photo handler as a side effect would be
/// a considerably worse bug than anything it could catch. Everything below is the pure derivation.
@MainActor
final class DefaultAppPromptTests: XCTestCase {

    /// The trap this whole feature tripped over first, pinned so it cannot come back.
    ///
    /// Every vendor RAW type conforms to `public.camera-raw-image`, so declaring the umbrella is enough
    /// to make Kelvin *able* to open an ARW and enough to put it in the Open With menu. It is not enough
    /// to be the DEFAULT: Launch Services resolves `_DSC6390.ARW` to `com.sony.arw-raw-image`, and
    /// claiming only the umbrella left every RAW opening in Adobe Lightroom while JPEG and PNG switched
    /// over correctly. Silent, and it reads as a broken app.
    func testTheConcreteVendorRawTypesAreClaimedAndNotJustTheUmbrella() {
        let types = Set(DefaultAppPrompt.allTypes)
        XCTAssertTrue(types.contains("public.camera-raw-image"),
                      "the umbrella is still wanted — it covers vendors not enumerated here")
        for concrete in ["com.sony.arw-raw-image", "com.canon.cr3-raw-image",
                         "com.nikon.raw-image", "com.adobe.raw-image"] {
            XCTAssertTrue(types.contains(concrete),
                          "\(concrete) must be claimed explicitly; conformance to the umbrella does "
                          + "NOT make Kelvin the default for it")
        }
    }

    /// The RAW list is derived from what Kelvin can actually decode, so a newly supported body becomes
    /// a newly claimable type without anyone remembering to edit two lists.
    func testEveryDecodableRawExtensionIsEitherClaimableOrHasNoSystemType() {
        let claimed = Set(DefaultAppPrompt.rawTypes)
        for ext in ImageDecoder.rawExtensions {
            guard let type = UTType(filenameExtension: ext) else { continue }  // nothing to declare
            if type.identifier.hasPrefix("dyn.") { continue }                  // ditto
            XCTAssertTrue(claimed.contains(type.identifier),
                          ".\(ext) decodes but its type \(type.identifier) is never claimed")
        }
    }

    /// A dynamic identifier means macOS has no declaration for the extension, so there is nothing to be
    /// the handler for. Claiming one would fail silently, which is the failure mode this file exists to
    /// avoid. `.x3f` (Sigma) is the real example.
    func testUndeclaredFormatsAreNotOffered() {
        for type in DefaultAppPrompt.rawTypes {
            XCTAssertFalse(type.hasPrefix("dyn."), "\(type) is not a type anything can be default for")
        }
        if let x3f = UTType(filenameExtension: "x3f"), x3f.identifier.hasPrefix("dyn.") {
            XCTAssertFalse(DefaultAppPrompt.rawTypes.contains(x3f.identifier))
        }
    }

    /// Every claimed type must be a real image type. Catches a typo'd identifier, which would otherwise
    /// be indistinguishable from "macOS refused" at runtime.
    func testEveryClaimedTypeIsARealImageType() {
        for id in DefaultAppPrompt.allTypes {
            let type = UTType(id)
            XCTAssertNotNil(type, "\(id) is not a content type macOS knows")
            guard let type else { continue }
            XCTAssertTrue(type.conforms(to: .image), "\(id) is not an image type")
        }
    }

    /// No duplicates. Claiming the same type twice is harmless but it inflates the "N of M refused"
    /// count in the failure alert, which would make a partial failure read as worse than it is.
    func testTheClaimListHasNoDuplicates() {
        let all = DefaultAppPrompt.allTypes
        XCTAssertEqual(all.count, Set(all).count, "duplicate entries: \(all.count - Set(all).count)")
    }

    /// The still-image list must match what the Info.plist declares, because Launch Services will not
    /// make an app the default for something its bundle never claimed to open. The two lists live in
    /// different files (`scripts/package-app.sh` and here) and drift silently.
    func testTheStillImageTypesMatchWhatThePackagedPlistDeclares() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // .../Tests/KelvinAppTests
            .deletingLastPathComponent()      // .../Tests
            .deletingLastPathComponent()      // .../KelvinPerceptionMLX
            .deletingLastPathComponent()      // .../Integrations
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("scripts/package-app.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        for type in DefaultAppPrompt.stillImageTypes {
            XCTAssertTrue(source.contains("<string>\(type)</string>"),
                          "\(type) is offered but the packaged Info.plist does not declare it, so "
                          + "Launch Services will refuse to make Kelvin its default")
        }
        XCTAssertTrue(source.contains("<string>public.camera-raw-image</string>"))
    }

    /// A dev build has no bundle identifier Launch Services can register, so the offer must not appear
    /// there — it would be offering something that cannot work. Tests run unbundled, which is exactly
    /// that case.
    func testTheOfferIsSuppressedOutsideAPackagedApp() {
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, Branding.bundleIdentifier,
                          "precondition: the test bundle is not the app bundle")
        XCTAssertFalse(DefaultAppPrompt.shouldOffer)
    }
}
