import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.calls += 1
            guard let handler = Self.handler else { throw CloudAPIError.invalidResponse }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "x-request-id": "fixture-request"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct CloudContractTests {
    static func expect(_ value: Bool, _ text: String) {
        guard value else { fatalError("FAIL: " + text) }
        print("PASS: " + text)
    }
    static func main() async throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let request = try DeepSeekClient.request(jpeg: jpeg, instruction: "自然肤色", key: "fixture-deepseek", model: "deepseek-flash")
        expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions", "DeepSeek goes directly to its official endpoint")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-deepseek", "DeepSeek uses its own credential")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let parts = messages[1]["content"] as! [[String: Any]]
        let image = parts[1]["image_url"] as! [String: Any]
        expect(image["url"] as? String == "data:image/jpeg;base64," + jpeg.base64EncodedString(), "Advice receives actual selected image bytes")
        expect(body["response_format"] != nil, "Structured JSON advice requested")
        expect((messages[0]["content"] as! String).contains("最多3条"), "Advice is bounded and natural")
        let prompt = NaturalPhotoPolicy.editPrompt("稍微降低天空高光")
        expect(NaturalPhotoPolicy.editPrompt(prompt) == prompt, "Natural prefix is idempotent")
        expect(NaturalPhotoPolicy.rules.contains("无需修改"), "No-edit advice remains valid")
        let edit = try SeedreamClient.request(jpeg: jpeg, prompt: prompt, key: "fixture-seedream", model: "doubao-seedream-5-0-pro-260628")
        let editBody = try JSONSerialization.jsonObject(with: edit.httpBody!) as! [String: Any]
        expect(edit.url?.host == "ark.cn-beijing.volces.com", "Seedream goes directly to official Ark")
        expect(edit.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-seedream", "Seedream uses its own credential")
        expect(editBody["prompt"] as? String == prompt, "Direct edits retain natural constraints exactly once")
        expect(editBody["response_format"] as? String == "url", "Persistent result link enables download-only recovery")
        expect(editBody["watermark"] as? Bool == true && editBody["sequential_image_generation"] == nil, "Preserve watermark and omit unsupported batch parameter")
        let download = try SeedreamClient.downloadRequest(URL(string: "https://fixture.example.invalid/result.jpg?signature=fixture")!)
        expect(download.value(forHTTPHeaderField: "Authorization") == nil, "Download URLs never receive API keys")
        for unsafe in ["http://example.invalid/result.jpg", "https://user:pass@example.invalid/result.jpg"] {
            do { _ = try CloudHTTP.safeImageURL(unsafe); fatalError("Unsafe URL accepted") }
            catch CloudAPIError.unsafeURL { print("PASS: unsafe download URL rejected") }
        }
        for key in ["", "key\r\ninjected", "key with space"] {
            do { _ = try DeepSeekClient.request(jpeg: jpeg, instruction: "自然", key: key, model: "deepseek-flash"); fatalError("Invalid key accepted") }
            catch { print("PASS: invalid credential rejected before network") }
        }
        do { _ = try SeedreamClient.request(jpeg: jpeg, prompt: "自然", key: "fixture", model: "bad/model"); fatalError("Bad model accepted") }
        catch CloudAPIError.invalidModel { print("PASS: invalid model rejected before network") }
        do { _ = try SeedreamClient.request(jpeg: jpeg, prompt: " ", key: "fixture", model: "valid"); fatalError("Empty prompt accepted") }
        catch CloudAPIError.invalidInput { print("PASS: empty edit prompt rejected") }
        let adviceObject: [String: Any] = ["scene": "山景人像", "strengths": ["光线自然"], "issues": [], "recommendations": [], "edit_prompt": "保持原片", "preserve": ["肤色"]]
        let content = String(data: try JSONSerialization.data(withJSONObject: adviceObject), encoding: .utf8)!
        let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "model": "deepseek-flash", "usage": ["prompt_tokens": 100, "completion_tokens": 30]])
        MockProtocol.calls = 0
        MockProtocol.handler = { request in
            expect(request.url?.host == "api.deepseek.com", "Advice does not call Seedream")
            return (200, reply)
        }
        let advice = try await DeepSeekClient(session: session).analyze(jpeg: jpeg, instruction: "自然", key: "fixture-deepseek", model: "deepseek-flash")
        expect(advice.advice.scene == "山景人像" && advice.usage.inputTokens == 100, "Advice and usage decoded")
        expect(MockProtocol.calls == 1, "One explicit analysis produces one request")
        MockProtocol.calls = 0
        MockProtocol.handler = { _ in (200, Data("{\"data\":[{\"url\":\"https://fixture.example.invalid/result.jpg\"}]}".utf8)) }
        let result = try await SeedreamClient(session: session).edit(jpeg: jpeg, prompt: "自然", key: "fixture-seedream", model: "valid-model")
        expect(result.imageURL.host == "fixture.example.invalid" && result.requestID == "fixture-request", "Result URL and request ID decoded before download")
        expect(MockProtocol.calls == 1, "Generation returns a link without generating again")
        for status in [401, 403, 429, 500] {
            MockProtocol.calls = 0
            MockProtocol.handler = { _ in (status, Data("fixture-deepseek-secret-upstream-error".utf8)) }
            do { _ = try await DeepSeekClient(session: session).analyze(jpeg: jpeg, instruction: "自然", key: "fixture-deepseek", model: "deepseek-flash"); fatalError("HTTP failure accepted") }
            catch {
                expect(!error.localizedDescription.contains("fixture-deepseek"), "Errors do not disclose provider credentials or payloads")
                expect(MockProtocol.calls == 1, "HTTP failure is not automatically retried")
            }
        }
        MockProtocol.handler = { _ in (200, Data("{\"choices\":[{\"message\":{\"content\":\"not-json\"}}]}".utf8)) }
        do { _ = try await DeepSeekClient(session: session).analyze(jpeg: jpeg, instruction: "自然", key: "fixture", model: "valid"); fatalError("Malformed advice accepted") }
        catch CloudAPIError.invalidAdvice { print("PASS: malformed advice cannot proceed to generation") }
        let excess = try JSONSerialization.data(withJSONObject: adviceObject.merging(["issues": ["1", "2", "3", "4"]]) { _, new in new })
        do { _ = try JSONDecoder().decode(PhotoAdvice.self, from: excess).validated(); fatalError("Overbroad advice accepted") }
        catch CloudAPIError.invalidAdvice { print("PASS: more than three issues rejected") }
        print("Direct-provider contract tests passed (mock transport only; no paid calls)")
    }
}
