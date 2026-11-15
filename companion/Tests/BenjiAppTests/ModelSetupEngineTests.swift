import XCTest
@testable import BenjiApp
import BenjiCore

final class ModelSetupEngineTests: XCTestCase {
    private let source = ModelSetupSource(provider: "claude", model: "test-model", destination: "Anthropic",
                                          host: "api.anthropic.com", origin: "Keychain", local: false,
                                          keyVariable: "ANTHROPIC_API_KEY")

    private func fixtureHome() throws -> URL {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("benji-setup-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func fixtureEnvironment(_ home: URL) -> [String: String] {
        ["HOME": home.path, "CFFIXED_USER_HOME": home.path,
         "BENJI_WORKDIR": home.appendingPathComponent("work").path,
         "BENJI_MIGRATION_GUARD": "abort", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
    }

    @MainActor private func run(_ script: String, test: ModelSetupSource? = nil, timeout: TimeInterval = 2,
                                additions: [String: String] = [:], inherited: [String: String] = [:]) async -> Result<ModelSetupSource, ModelSetupFailure> {
        let home = try! fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = inherited.merging(fixtureEnvironment(home)) { _, fixture in fixture }
        let done = expectation(description: "fake setup process finished")
        var result: Result<ModelSetupSource, ModelSetupFailure>?
        let engine = ModelSetupEngine(assistantDir: "/private/tmp", environment: { .success(additions) },
                                      executable: URL(fileURLWithPath: "/bin/sh"),
                                      arguments: ["-c", "/bin/cat >/dev/null\n" + script],
                                      timeoutSeconds: timeout, inheritedEnvironment: { isolated })
        engine.run(test: test) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return result ?? .failure(ModelSetupFailure(words: "fake process did not finish"))
    }

    private func reply() throws -> String {
        let data = try JSONEncoder().encode(source)
        return "{\"ok\":true,\"source\":" + String(decoding: data, as: UTF8.self) + "}"
    }

    @MainActor func testProfileNoiseBeforeDedicatedReplyAndTrailingNoiseAreIgnored() async throws {
        let result = await run("printf 'profile output without newline'; printf '\\n%s\\n\\ntrailing noise\\n' '\(try reply())'")
        XCTAssertEqual(try result.get(), source)
    }

    @MainActor func testLastDecodableReplyWins() async throws {
        let result = await run("printf '%s\\n%s\\n' '{\"ok\":false,\"error\":\"old reply\"}' '\(try reply())'")
        XCTAssertEqual(try result.get(), source)
    }

    @MainActor func testTimeoutSaysRequestMayHaveReachedModel() async {
        let result = await run("exec /bin/sleep 5", timeout: 0.05)
        guard case let .failure(error) = result else { return XCTFail("expected timeout") }
        XCTAssertEqual(error.words, "The test timed out. The request may have reached the model.")
    }

    @MainActor func testNonJSONOutputHasPlainReadFailure() async {
        let result = await run("printf 'some profile output\\nnot a reply\\n'")
        guard case let .failure(error) = result else { return XCTFail("expected read failure") }
        XCTAssertTrue(error.words.contains("couldn't read"))
    }

    @MainActor func testNonzeroExitShowsOnlyShortRedactedStderrTail() async {
        let details = String(repeating: "detail ", count: 100) + "fake-model-value TOKEN=fake-token-value"
        let result = await run("printf '%s' '\(details)' >&2; exit 1", test: source,
                               additions: ["ANTHROPIC_API_KEY": "fake-model-value"])
        guard case let .failure(error) = result else { return XCTFail("expected start failure") }
        XCTAssertTrue(error.words.contains("couldn't start"))
        XCTAssertTrue(error.words.contains("[key]"))
        XCTAssertTrue(error.words.contains("[redacted]"))
        XCTAssertFalse(error.words.contains("fake-model-value"))
        XCTAssertFalse(error.words.contains("fake-token-value"))
        XCTAssertLessThanOrEqual(error.words.components(separatedBy: "\n").last?.count ?? 999, 300)
    }

    @MainActor func testProviderErrorIsRedactedThenBounded() async {
        let words = "fake-model-value " + String(repeating: "detail ", count: 100)
        let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": words])
        let result = await run("printf '%s\\n' '\(String(decoding: data, as: UTF8.self))'", test: source,
                               additions: ["ANTHROPIC_API_KEY": "fake-model-value"])
        guard case let .failure(error) = result else { return XCTFail("expected provider failure") }
        XCTAssertLessThanOrEqual(error.words.count, 300)
        XCTAssertTrue(error.words.contains("[key]"))
        XCTAssertFalse(error.words.contains("fake-model-value"))
    }

    @MainActor func testProbeReceivesPresenceMarkersAndNoSecretValues() async throws {
        let script = """
        [ "$ANTHROPIC_API_KEY" = setup-key-present ] || exit 21
        [ "$OPENAI_API_KEY" = setup-key-present ] || exit 22
        [ "$SERPAPI_KEY" = setup-key-present ] || exit 23
        [ "$BENJI_SETUP_KEYCHAIN_KEYS" = ANTHROPIC_API_KEY,SERPAPI_KEY ] || exit 24
        printf '%s\n' '\(try reply())'
        """
        let result = await run(script, additions: ["ANTHROPIC_API_KEY": "fake-anthropic-value", "SERPAPI_KEY": "fake-search-value"],
                               inherited: ["OPENAI_API_KEY": "fake-openai-value"])
        XCTAssertEqual(try result.get(), source)
    }

    @MainActor func testTestReceivesOnlyChosenProvidersKey() async throws {
        let script = """
        [ "$ANTHROPIC_API_KEY" = fake-anthropic-value ] || exit 21
        [ "${OPENAI_API_KEY+x}" != x ] || exit 22
        [ "${SERPAPI_KEY+x}" != x ] || exit 23
        printf '%s\n' '\(try reply())'
        """
        let result = await run(script, test: source,
                               additions: ["ANTHROPIC_API_KEY": "fake-anthropic-value", "SERPAPI_KEY": "fake-search-value"],
                               inherited: ["OPENAI_API_KEY": "fake-openai-value"])
        XCTAssertEqual(try result.get(), source)
    }

    @MainActor func testKeylessLocalTestRoundTripsThroughPythonWithoutHTTP() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = fixtureEnvironment(home)
        let done = expectation(description: "offline Python setup protocol")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let local = ModelSetupSource(provider: "ollama", model: "test-local", destination: "Ollama on this computer",
                                     host: "localhost:11434", origin: "local model settings", local: true, usesKey: false)
        let code = """
        import os,sys
        assert os.environ["HOME"] == \(String(reflecting: home.path))
        assert os.environ["BENJI_WORKDIR"].startswith(os.environ["HOME"] + "/")
        assert not any(name.endswith("_API_KEY") and value for name,value in os.environ.items())
        sys.path.insert(0,os.environ["BENJI_DIR"])
        from benji import providers,model_setup
        providers._post=lambda *a,**kw: {"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}],"usage":{}}
        model_setup.model_setup_main()
        """
        let engine = ModelSetupEngine(assistantDir: root, environment: { .success([
            "BENJI_PROVIDER": "ollama", "BENJI_MODEL": "test-local", "BENJI_API_KEY": "",
            "BENJI_BASE_URL": "http://localhost:11434/v1", "BENJI_KEY_SOURCE": "keychain",
        ]) }, executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["python3", "-c", code], inheritedEnvironment: { isolated })
        var result: Result<ModelSetupSource, ModelSetupFailure>?
        engine.run(test: local) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(result).get(), local)
    }

    @MainActor func testMissingExecutableGivesStartFailure() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = fixtureEnvironment(home)
        let done = expectation(description: "missing executable")
        let engine = ModelSetupEngine(assistantDir: "/private/tmp", environment: { .success([:]) },
                                      executable: URL(fileURLWithPath: "/private/tmp/benji-missing-\(UUID().uuidString)"),
                                      arguments: [], inheritedEnvironment: { isolated })
        engine.run(test: nil) { result in
            guard case let .failure(error) = result else { XCTFail("expected start failure"); done.fulfill(); return }
            XCTAssertTrue(error.words.contains("couldn't start"))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 3)
    }
}
