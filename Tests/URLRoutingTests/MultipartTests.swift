import Foundation
import Parsing
import XCTest

@testable import URLRouting

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class MultipartTests: XCTestCase {
  enum TestRoute: Equatable {
    case multipart(one: String, two: Model)
  }
  
  struct Model: Codable, Equatable {
    var string: String
    var integer: Int
  }

  struct TestRouter: ParserPrinter {
    var body: some Router<TestRoute> {
      OneOf {
        Route(.case(TestRoute.multipart)) {
          Method.post
          Path { "upload" }
          Multipart(boundary: "abcde12345") {
            Part {
              PartHeaders {
                Field("Content-Type") { "text/plain" }
              }
              PartBody(DataToSubstring(encoding: .utf8).string)
            }
            Part {
              PartHeaders {
                Field("Content-Type") { "application/json" }
              }
              PartBody(.json(Model.self))
            }
          }
        }
      }
    }
  }
  
  func testBasics() throws {
    var request = URLRequestData(string: "https://www.example.com/upload")!
    request.method = "POST"
    request.headers["Content-Type"] = ["multipart/form-data; boundary=abcde12345"]
    request.body = """
    --abcde12345
    Content-Disposition: form-data; name="id"
    Content-Type: text/plain
    
    123e4567-e89b-12d3-a456-426655440000
    --abcde12345
    Content-Disposition: form-data; name="address"
    Content-Type: application/json
    
    {
      "string": "Hello world",
      "integer": 123
    }
    --abcde12345--
    """.data(using: .utf8)

    let output = try TestRouter().parse(&request)
    XCTAssertEqual(output, .multipart(
      one: "123e4567-e89b-12d3-a456-426655440000",
      two: .init(string: "Hello world", integer: 123)
    ))
    XCTAssert(request.body!.isEmpty)
  }
  
  func testHeaderLineParser() throws {
    let output = try PartHeaderLine().parse("Content-Type: text/plain".data(using: .utf8)!)
    XCTAssertEqual("Content-Type", output.0)
    XCTAssertEqual("text/plain", output.1)
  }
  
  func testPartHeaderFieldsParser() throws {
    var inputData = """
      Content-Disposition: form-data; name="id"
      Content-Type: text/plain
      
      data starts here
      """.data(using: .utf8)!
    
    let expected: URLRequestData.Fields = [
      "Content-Disposition": [#"form-data; name="id""#],
      "Content-Type": ["text/plain"]
    ]
    let output = try PartHeaderFields().parse(&inputData)
    XCTAssertEqual(output, expected)
    XCTAssertEqual("data starts here".data(using: .utf8), inputData)
  }
  
  func testPartParser() throws {
    var inputData = """
    --abcde12345
    Content-Disposition: form-data; name="id"
    Content-Type: text/plain
    
    This is some text
    --abcde12345
    Content-Disposition: form-data; name="text"
    Content-Type: text/plain
    
    This is some more text
    --abcde12345--
    """.data(using: .utf8)!
    
    let expected = PartData(
      headers: [
        "Content-Disposition": [#"form-data; name="id""#],
        "Content-Type": ["text/plain"]
      ],
      body: "This is some text".data(using: .utf8)!
    )
    let output = try PartParser(boundaryValue: "abcde12345").parse(&inputData)
    
    print(String(data: inputData, encoding: .utf8)!)
    XCTAssertEqual(output, expected)
  }
  
  func testPartsParser() throws {
    var inputData = """
    --abcde12345
    Content-Disposition: form-data; name="id"
    Content-Type: text/plain
    
    This is some text
    --abcde12345
    Content-Disposition: form-data; name="text"
    Content-Type: text/plain
    
    This is some more text
    --abcde12345--
    """.data(using: .utf8)!
    
    let expected: [PartData] = [
      PartData(
        headers: [
          "Content-Disposition": [#"form-data; name="id""#],
          "Content-Type": ["text/plain"]
        ],
        body: "This is some text".data(using: .utf8)!
      ),
      PartData(
        headers: [
          "Content-Disposition": [#"form-data; name="text""#],
          "Content-Type": ["text/plain"]
        ],
        body: "This is some more text".data(using: .utf8)!
      )
    ]
    let output = try PartsParser(boundaryValue: "abcde12345").parse(&inputData)
    print(String(data: inputData, encoding: .utf8)!)
    XCTAssertEqual(output, expected)
    XCTAssert(inputData.isEmpty)
  }
}
