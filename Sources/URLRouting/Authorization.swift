import CasePaths
import Foundation
import Parsing

/// Represents a way of authorizing a URL request.
public enum Authorization: Equatable {
  /// Request is authorized using a bearer token in the "authorization" header.
  case bearer(String)

  /// Allows requests to be authorized using a query parameter - e.g. API tokens.
  case query(String)

  /// Allows requests to be authorized using a custom HTTP header.
  case custom(String)
}

public typealias AuthorizationParser = AnyParserPrinter<URLRequestData, Authorization>

public extension AuthorizationParser {
  /// Parses a Bearer authorization token from the Authorization header.
  static var bearer: Self {
    ParsePrint(/Authorization.bearer) {
      Headers {
        Field("Authorization") {
          "Bearer "
          Parse(.string)
        }
      }
    }
    .eraseToAnyParserPrinter()
  }

  /// Parses an authorization token from the specified query parameter.
  static func query(_ param: String) -> AnyParserPrinter<URLRequestData, Authorization> {
    ParsePrint(/Authorization.query) {
      Query {
        Field(param) {
          Parse(.string)
        }
      }
    }
    .eraseToAnyParserPrinter()
  }

  /// Parses an authorization token from a custom HTTP header.
  static func custom(_ header: String) -> AnyParserPrinter<URLRequestData, Authorization> {
    ParsePrint(/Authorization.custom) {
      Headers {
        Field(header) {
          Parse(.string)
        }
      }
    }
    .eraseToAnyParserPrinter()
  }
}

/// Represents a protected route that requires authorization to access.
public struct Authorized<Route> {
  /// The method of authorizing access to this route.
  public let authorization: Authorization

  /// The protected route.
  public let route: Route

  public init(authorization: Authorization, route: Route) {
    self.authorization = authorization
    self.route = route
  }
}

extension Authorized: Equatable where Route: Equatable {}

public struct Authorize<Parsers: ParserPrinter>: ParserPrinter where Parsers.Input == URLRequestData {
  @usableFromInline
  let parsers: Parsers

  @inlinable
  public init<RouteParsers>(
    with authorization: AuthorizationParser,
    @ParserBuilder _ build: () -> RouteParsers
  )
  where
    RouteParsers: ParserPrinter,
    Parsers == Parsing.Parsers.MapConversion<
      ParsePrint<ParserBuilder.ZipOO<AuthorizationParser, RouteParsers>>,
      Conversions.Memberwise<
        (Authorization, RouteParsers.Output),
        Authorized<RouteParsers.Output>
      >
    >
  {
    self.parsers = ParsePrint {
      authorization
      build()
    }
    .map(.memberwise(Authorized.init))
  }

  @inlinable
  public func parse(_ input: inout URLRequestData) throws -> Parsers.Output {
    try self.parsers.parse(&input)
  }

  @inlinable
  public func print(_ output: Parsers.Output, into input: inout URLRequestData) rethrows {
    try self.parsers.print(output, into: &input)
  }
}

public struct UnauthorizedRoute: Error {
  init() {}
}

extension URLRoutingClient {
  /// Returns a client that is scoped to perform authorized local routes.
  ///
  /// The returned client will automatically construct `Authorized` routes using the current authorization
  /// by calling `self.authorization()` - if this returns `nil` a `UnuthorizedRoute` error will
  /// be thrown.
  ///
  /// - Parameters:
  ///   - toRoute: A function that converts an authorized local route back to a more global route.
  public func scoped<LocalRoute>(
    to toRoute: @escaping (Authorized<LocalRoute>) -> Route
  ) -> URLRoutingClient<LocalRoute> {
    .init(
      request: { localRoute in
        guard let authorization = self.authorization() else {
          throw UnauthorizedRoute()
        }
        return try await self.request(
          toRoute(
            .init(
              authorization: authorization,
              route: localRoute
            )
          )
        )
      },
      authorization: self.authorization,
      setAuthorization: self.setAuthorization
    )
  }
}
