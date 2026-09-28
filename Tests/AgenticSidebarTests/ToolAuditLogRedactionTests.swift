import XCTest

@testable import AgenticSidebar

/// `ToolAuditLog.redact` için hermetik testler: saf fonksiyon, dosya ve ağ yok.
///
/// Denetim günlüğü aracı ayrıntılarını diske yazar; maskeleme kaçırırsa sır
/// kalıcı olur. Bu testler bilinen belirteç biçimlerinin maskelendiğini ve
/// ayraçsız düz sözcüklerin yanlış pozitif vermediğini kilitler.
final class ToolAuditLogRedactionTests: XCTestCase {
    func testBearerSchemeIsPreservedWhileTokenIsMasked() {
        XCTAssertEqual(ToolAuditLog.redact("Bearer abc123"), "Bearer [REDACTED]")
        XCTAssertEqual(ToolAuditLog.redact("Basic abc123"), "Basic [REDACTED]")
    }

    func testKnownTokenFormatsAreMasked() {
        XCTAssertFalse(ToolAuditLog.redact("key AKIAIOSFODNN7EXAMPLE").contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(ToolAuditLog.redact("token ghp_ABCDEFGHIJKLMNOPQRST").contains("ghp_ABCDEFGHIJKLMNOPQRST"))
        XCTAssertFalse(ToolAuditLog.redact("token xoxb-123456789012-ABCDEFGHIJ").contains("xoxb-123456789012"))
        XCTAssertFalse(ToolAuditLog.redact("key sk-proj-abcdefgh12345678").contains("sk-proj-abcdefgh12345678"))
        XCTAssertFalse(ToolAuditLog.redact("key sk-live-abcdefgh12345678").contains("sk-live-abcdefgh12345678"))
    }

    func testExtendedTokenFamiliesAreMasked() {
        XCTAssertFalse(ToolAuditLog.redact("key sk-ant-abcdefgh12345678").contains("sk-ant-abcdefgh12345678"))
        XCTAssertFalse(
            ToolAuditLog.redact("token xoxo-123456789012-ABCDEFGHIJ").contains("xoxo-123456789012")
        )
        XCTAssertFalse(
            ToolAuditLog.redact("token xoxr-123456789012-ABCDEFGHIJ").contains("xoxr-123456789012")
        )
        XCTAssertFalse(
            ToolAuditLog.redact("key AIzaSyABCDEFGHIJKLMNOPQRSTUVWX").contains("AIzaSyABCDEFGHIJKLMNOPQRSTUVWX")
        )
        XCTAssertFalse(
            ToolAuditLog.redact("token glpat-abcdefgh1234567890").contains("glpat-abcdefgh1234567890")
        )
        XCTAssertFalse(
            ToolAuditLog.redact("token github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcd")
                .contains("github_pat_")
        )
    }

    func testPrivateKeyBlockIsMasked() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBPAIBAA==\n-----END RSA PRIVATE KEY-----"
        let redacted = ToolAuditLog.redact(pem)
        XCTAssertFalse(redacted.contains("MIIBPAIBAA"))
        XCTAssertTrue(redacted.contains("[REDACTED PRIVATE KEY]"))
    }

    func testKeyValueSecretIsMasked() {
        let redacted = ToolAuditLog.redact(#"{"api_key": "ABCDEF1234567890"}"#)
        XCTAssertFalse(redacted.contains("ABCDEF1234567890"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testBareWordWithoutSeparatorIsUntouched() {
        XCTAssertEqual(ToolAuditLog.redact("the token arrived"), "the token arrived")
    }
}
