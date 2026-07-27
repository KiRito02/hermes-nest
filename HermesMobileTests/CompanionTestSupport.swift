import XCTest
@testable import HermesMobile

class CompanionHTTPTestCase: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class InMemoryKeychainStore: KeychainStoring {
    private(set) var savedValues: [KeychainStore.Key: String] = [:]
    private(set) var saveCounts: [KeychainStore.Key: Int] = [:]
    private(set) var scopedValues: [String: String] = [:]

    func save(_ value: String, forKey key: KeychainStore.Key) throws {
        savedValues[key] = value
        saveCounts[key, default: 0] += 1
    }

    func load(_ key: KeychainStore.Key) throws -> String? {
        savedValues[key]
    }

    func delete(_ key: KeychainStore.Key) throws {
        savedValues.removeValue(forKey: key)
    }

    func save(
        _ value: String,
        forKey key: KeychainStore.Key,
        scope: String
    ) throws {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)] = value
    }

    func load(
        _ key: KeychainStore.Key,
        scope: String
    ) throws -> String? {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)]
    }

    func delete(
        _ key: KeychainStore.Key,
        scope: String
    ) throws {
        scopedValues.removeValue(
            forKey: KeychainStore.scopedKey(key, scope: scope)
        )
    }

    func scopedValue(
        _ key: KeychainStore.Key,
        scope: String
    ) -> String? {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)]
    }
}

func apiTestJSONResponse(
    _ json: String,
    for request: URLRequest
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(json.utf8))
}

func apiTestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: bufferSize
    )
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

func apiTestJSONBody(
    from request: URLRequest
) throws -> [String: Any] {
    let data = try XCTUnwrap(apiTestBodyData(from: request))
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
