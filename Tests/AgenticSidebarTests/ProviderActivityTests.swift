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

final class SubagentAndMCPActivityKindTests: XCTestCase {
    func testTheTaskToolIsASubagentDelegationNotATodoUpdate() {
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("p-task"),
                toolName: "task"
            ).kind,
            .subagent
        )
    }

    func testTaskListToolsAreStillTodo() {
        for toolName in ["todowrite", "todo_write", "todoread"] {
            XCTAssertEqual(
                ProviderActivityDescriptor.sanitizedTool(
                    id: ProviderActivityID("p-\(toolName)"),
                    toolName: toolName
                ).kind,
                .todo,
                "\(toolName) must keep driving the checklist"
            )
        }
    }

    func testMCPToolNamesAreRecognisedInBothConventions() {
        for toolName in ["mcp__github__get_user", "mcp_github_get_user"] {
            XCTAssertEqual(
                ProviderActivityDescriptor.sanitizedTool(
                    id: ProviderActivityID("p-\(toolName)"),
                    toolName: toolName
                ).kind,
                .mcp,
                "\(toolName) must render as an MCP call"
            )
        }
    }

    func testModernMCPNameSplitsServerFromTool() {
        XCTAssertEqual(
            ProviderActivityDescriptor.mcpServerAndTool(from: "mcp__github__get_user").server,
            "github"
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.mcpServerAndTool(from: "mcp__github__get_user").tool,
            "get_user"
        )
    }

    func testColonSeparatedMCPNameSplitsServerFromTool() {
        let parsedWithColon = ProviderActivityDescriptor.mcpServerAndTool(from: "mcp:github:get_user")
        XCTAssertEqual(parsedWithColon.server, "github")
        XCTAssertEqual(parsedWithColon.tool, "get_user")

        let parsedWithUnderscores = ProviderActivityDescriptor.mcpServerAndTool(from: "mcp:github_get_user")
        XCTAssertEqual(parsedWithUnderscores.server, "github")
        XCTAssertEqual(parsedWithUnderscores.tool, "get_user")
    }

    func testLegacyMCPNameDoesNotClaimAServer() {
        let parsed = ProviderActivityDescriptor.mcpServerAndTool(from: "mcp_my_server_query")
        XCTAssertNil(parsed.server)
        XCTAssertEqual(parsed.tool, "my_server_query")
    }

    func testToolNameHumanization() {
        XCTAssertEqual(
            ProviderActivityDescriptor.humanizedToolName("get_user"),
            "Get User"
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.humanizedToolName("read"),
            "Read"
        )
    }

    func testSubagentToolVariants() {
        let subagentTools = [
            "task",
            "subagent",
            "sub_agent",
            "browser_subagent",
            "run_subagent",
            "call_subagent",
            "invoke_subagent",
            "delegate_task",
            "delegate_agent",
            "delegate",
            "agent"
        ]
        for tool in subagentTools {
            XCTAssertEqual(
                ProviderActivityDescriptor.sanitizedTool(
                    id: ProviderActivityID("p-\(tool)"),
                    toolName: tool
                ).kind,
                .subagent,
                "\(tool) must be identified as .subagent"
            )
        }
    }

    func testCallMCPToolWithInputParameters() {
        let descriptor = ProviderActivityDescriptor.sanitizedTool(
            id: ProviderActivityID("p-mcp"),
            toolName: "call_mcp_tool"
        )
        XCTAssertEqual(descriptor.kind, .mcp)

        let parsed = ProviderActivityDescriptor.mcpServerAndTool(
            from: "call_mcp_tool",
            input: [
                "ServerName": "chrome-devtools-mcp",
                "ToolName": "take_screenshot"
            ]
        )
        XCTAssertEqual(parsed.server, "chrome-devtools-mcp")
        XCTAssertEqual(parsed.tool, "take_screenshot")
    }

    func testSubagentAndMCPPresentations() {
        let subagent = AgentActivityPresentation(kind: .subagent)
        XCTAssertEqual(subagent.title, "Delegated to subagent")
        XCTAssertEqual(subagent.runningStatusName, "Running subagent")
        XCTAssertFalse(subagent.symbolName.isEmpty)

        let mcp = AgentActivityPresentation(kind: .mcp)
        XCTAssertEqual(mcp.title, "Using MCP tool")
        XCTAssertEqual(mcp.runningStatusName, "MCP tool")
        XCTAssertFalse(mcp.symbolName.isEmpty)
    }
}
