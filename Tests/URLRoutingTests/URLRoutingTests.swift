import CasePaths
import Parsing
import URLRouting
import XCTest

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

class URLRoutingTests: XCTestCase {
  func testMethod() {
    XCTAssertNoThrow(try Method.post.parse(URLRequestData(method: "POST")))
    XCTAssertEqual(try Method.post.print(), URLRequestData(method: "POST"))
  }

  func testPath() {
    XCTAssertEqual(123, try Path { Int.parser() }.parse(URLRequestData(path: "/123")))
    XCTAssertThrowsError(try Path { Int.parser() }.parse(URLRequestData(path: "/123-foo"))) {
      error in
      XCTAssertEqual(
        """
        error: unexpected input
         --> input:1:5
        1 | /123-foo
          |     ^ expected end of input
        """,
        "\(error)"
      )
    }
  }

  func testFormData() throws {
    let p = Body {
      FormData {
        Field("name", .string)
        Field("age") { Int.parser() }
      }
    }

    var request = URLRequestData(body: .init("name=Blob&age=42&debug=1".utf8))
    let (name, age) = try p.parse(&request)
    XCTAssertEqual("Blob", name)
    XCTAssertEqual(42, age)
    XCTAssertEqual("debug=1", request.body.map { String(decoding: $0, as: UTF8.self) })
  }

  func testHeaders() throws {
    let p = Headers {
      Field("X-Haha", .string)
    }

    var req = URLRequest(url: URL(string: "/")!)
    req.addValue("Hello", forHTTPHeaderField: "X-Haha")
    req.addValue("Blob", forHTTPHeaderField: "X-Haha")
    var request = URLRequestData(request: req)!

    let name = try p.parse(&request)
    XCTAssertEqual("Hello", name)
    XCTAssertEqual(["X-Haha": ["Blob"]], request.headers)
  }

  func testQuery() throws {
    let p = Query {
      Field("name")
      Field("age") { Int.parser() }
    }

    var request = URLRequestData(string: "/?name=Blob&age=42&debug=1")!
    let (name, age) = try p.parse(&request)
    XCTAssertEqual("Blob", name)
    XCTAssertEqual(42, age)
    XCTAssertEqual(["debug": ["1"]], request.query)
  }

  func testQueryDefault() throws {
    let p = Query {
      Field("page", default: 1) {
        Int.parser()
      }
    }

    var request = URLRequestData(string: "/")!
    let page = try p.parse(&request)
    XCTAssertEqual(1, page)
    XCTAssertEqual([:], request.query)

    XCTAssertEqual(
      try p.print(10),
      URLRequestData(query: ["page": ["10"]])
    )
    XCTAssertEqual(
      try p.print(1),
      URLRequestData(query: [:])
    )
  }

  func testCookies() throws {
    struct Session: Equatable {
      var userId: Int
      var isAdmin: Bool
    }

    let p = Cookies /*(.destructure(Session.init(userId:isAdmin:)))*/ {
      Field("userId") { Int.parser() }
      Field("isAdmin") { Bool.parser() }
    }
    .map(.memberwise(Session.init(userId:isAdmin:)))

    var request = URLRequestData(headers: ["cookie": ["userId=42; isAdmin=true"]])
    XCTAssertEqual(
      Session(userId: 42, isAdmin: true),
      try p.parse(&request)
    )
    XCTAssertEqual(
      URLRequestData(headers: ["cookie": ["isAdmin=true; userId=42"]]),
      try p.print(Session(userId: 42, isAdmin: true))
    )
  }

  func testJSONCookies() {
    struct Session: Codable, Equatable {
      var userId: Int
    }

    let p = Cookies {
      Field("pf_session", .utf8.data.json(Session.self))
    }

    var request = URLRequestData(headers: ["cookie": [#"pf_session={"userId":42}; foo=bar"#]])
    XCTAssertEqual(
      Session(userId: 42),
      try p.parse(&request)
    )
    XCTAssertEqual(
      URLRequestData(headers: ["cookie": [#"pf_session={"userId":42}"#]]),
      try p.print(Session(userId: 42))
    )
  }

  func testBaseURL() throws {
    enum AppRoute { case home, episodes }

    let router = OneOf {
      Route(AppRoute.home)
      Route(AppRoute.episodes) {
        Path { "episodes" }
      }
    }

    XCTAssertEqual(
      "https://api.pointfree.co/v1/episodes?token=deadbeef",
      URLRequest(
        data:
          try router
          .baseURL("https://api.pointfree.co/v1?token=deadbeef")
          .print(.episodes)
      )?.url?.absoluteString
    )

    XCTAssertEqual(
      "http://localhost:8080/v1/episodes?token=deadbeef",
      URLRequest(
        data:
          try router
          .baseURL("http://localhost:8080/v1?token=deadbeef")
          .print(.episodes)
      )?.url?.absoluteString
    )
  }

  func testAuthorization() throws {
    enum AppRoute {
      case `public`(PublicRoute)
      case `private`(Authorized<PrivateRoute>)
    }

    enum PublicRoute {
      case signup
    }

    enum PrivateRoute {
      case account
    }

    let privateRouter = OneOf {
      Route(/PrivateRoute.account) {
        Path { "account" }
      }
    }

    let router = OneOf {
      Route(/AppRoute.public) {
        OneOf {
          Route(PublicRoute.signup) {
            Path { "signup" }
          }
        }
      }
      Route(/AppRoute.private) {
        // For this test we'll support all types of
        // authorization methods.
        OneOf {
          Authorize(with: .bearer) {
            privateRouter
          }
          Authorize(with: .query("token")) {
            privateRouter
          }
          Authorize(with: .custom("X-API-Token")) {
            privateRouter
          }
        }
      }
    }

    XCTAssertEqual(
      URLRequestData(
        path: "/account",
        headers: ["Authorization": ["Bearer deadbeef"]]
      ),
      try router.print(
        AppRoute.private(
          .init(
            authorization: .bearer("deadbeef"),
            route: .account
          )
        )
      )
    )
    XCTAssertEqual(
      URLRequestData(
        path: "/account",
        headers: ["X-API-Token": ["deadbeef"]]
      ),
      try router.print(
        AppRoute.private(
          .init(
            authorization: .custom("deadbeef"),
            route: .account
          )
        )
      )
    )
    XCTAssertEqual(
      URLRequestData(
        path: "/account",
        query: ["token": ["deadbeef"]]
      ),
      try router.print(
        AppRoute.private(
          .init(
            authorization: .query("deadbeef"),
            route: .account
          )
        )
      )
    )
  }

  func testAuthorizedClient() async throws {
    enum AppRoute: Equatable {
      case `public`
      case `private`(Authorized<PrivateRoute>)
    }
    enum PrivateRoute: Equatable {
      case account
    }

    let client = URLRoutingClient<AppRoute>.failing
      .override(
        .private(.init(authorization: .bearer("deadbeef"), route: .account)),
        with: { try .ok("it worked") }
      )

    do {
      _ = try await client
        .scoped(to: AppRoute.private)
        .request(.account, as: String.self)
      XCTFail("Request should not be authorized")
    } catch {
      XCTAssert(error is UnauthorizedRoute)
    }

    let result = try await client
      .overrideAuthorization { .bearer("deadbeef") }
      .scoped(to: AppRoute.private)
      .request(.account, as: String.self)

    XCTAssertEqual("it worked", result.value)
  }
}