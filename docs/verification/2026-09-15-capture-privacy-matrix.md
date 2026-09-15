# Capture Privacy Host Matrix — 2026-09-15

## Scope
This matrix records observed host behavior for the first AgenticSidebar milestone. It does not claim guaranteed exclusion from macOS screenshots, screen recording, or arbitrary third-party capture tools.

## Host
- macOS: 26.6.2
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- App baseline under test: M4 commit `7b6007d53af3f69a05808feeabe655f2366eb6e0` plus M5 acceptance-only test/docs changes

## Product contract
`CapturePrivacyCapabilities.current` reports:
- `externalCaptureExclusionGuaranteed = false`
- `supportsSelfCaptureFiltering = true`
- limitation: macOS does not provide a supported API that guarantees the AgenticSidebar window is omitted from system screenshots or arbitrary third-party capture. ScreenCaptureKit filters can exclude this app from captures initiated by this app.

## Matrix

| Capture path | Host procedure | Observed result | Acceptance interpretation |
| --- | --- | --- | --- |
| macOS window screenshot | Located the onscreen `AgenticSidebar` main window through CoreGraphics and invoked `/usr/sbin/screencapture -x -l <window-id>` | **Captured successfully**. PNG was 2184×1584 and 567,851 bytes. Temporary image was deleted immediately after metadata inspection. | Confirms there is no guaranteed external/system screenshot exclusion. This is expected and must not be represented as a product failure or hidden guarantee. |
| Legacy `NSWindow` sharing restriction | `CapturePrivacyControllerTests.testConfigureDoesNotApplyLegacyWindowSharingRestriction` | **PASS**; controller leaves the original `window.sharingType` unchanged. | The app does not use legacy/private behavior to imply stronger capture protection. |
| Capability claim | `CapturePrivacyControllerTests.testCapabilitiesNeverClaimGuaranteedExternalCaptureExclusion` | **PASS**; external exclusion guarantee remains false. | User-visible/product claims remain within supported macOS guarantees. |
| App-owned ScreenCaptureKit filtering | No first-milestone app-owned capture workflow exists to exercise a real ScreenCaptureKit stream. | **Not exercised / not applicable to current product flow.** | `supportsSelfCaptureFiltering` describes what an app-owned ScreenCaptureKit capture can do if such a flow is added; it is not evidence of external capture exclusion. |
| Arbitrary third-party recorder | No exhaustive recorder matrix was run. | **Not guaranteed / not exhaustively tested.** | The product explicitly does not promise invisibility to arbitrary third-party tools. |

## Automated evidence
Focused command:

```text
swift test --filter CapturePrivacyControllerTests
Executed 2 tests, with 0 failures.
```

Static scan found no production use of `sharingType`, `NSWindow.SharingType.none`, or equivalent external-capture suppression code. The only production reference to external exclusion is the explicit `externalCaptureExclusionGuaranteed: false` capability declaration.

## Conclusion
Capture privacy behavior satisfies the approved first-milestone contract only as a **best-effort, accurately disclosed limitation**. On this host the app window is capturable by supported macOS screenshot tooling, so no stronger claim is justified.
