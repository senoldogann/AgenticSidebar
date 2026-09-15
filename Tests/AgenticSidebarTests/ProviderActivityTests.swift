import XCTest
@testable import AgenticSidebar

final class ProviderActivityTests: XCTestCase {
    func testKnownToolNamesMapToSafeProviderNeutralKinds() {
        let cases: [(String, ProviderActivityKind)] = [
            ("read", .read),
            ("grep_files", .read),
            ("delete_file", .delete),
            ("write", .update),
            ("apply_patch", .edit),
            ("web_search", .webSearch)
        ]

        for (toolName, expectedKind) in cases {
            let descriptor = ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("part-1"),
                toolName: toolName
            )

            XCTAssertEqual(descriptor.kind, expectedKind)
        }
    }

    func testUnknownToolNameMapsToGenericKindWithoutRetainingRawName() {
        let descriptor = ProviderActivityDescriptor.sanitizedTool(
            id: ProviderActivityID("part-opaque"),
            toolName: "opaque_backend_tool_42"
        )

        XCTAssertEqual(
            descriptor,
            ProviderActivityDescriptor(
                id: ProviderActivityID("part-opaque"),
                kind: .tool
            )
        )
    }

    func testGenericToolPresentationDoesNotExposeUnknownRawName() {
        let presentation = AgentActivityPresentation(kind: .tool)

        XCTAssertEqual(presentation.title, "Using a tool")
        XCTAssertEqual(presentation.runningStatusName, "Tool")
    }
}
