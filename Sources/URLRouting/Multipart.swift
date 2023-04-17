import Parsing
import Foundation

/// Parses a multipart request body into well structured parts.
public struct Multipart<PartParsers: Parser>: Parser where PartParsers.Input == ArraySlice<PartData> {
  let boundaryValue: String
  let partParsers: PartParsers

  public init(boundary: String, @ParserBuilder<ArraySlice<PartData>> build: () -> PartParsers) {
    self.boundaryValue = boundary
    self.partParsers = build()
  }

  public func parse(_ input: inout URLRequestData) throws -> PartParsers.Output {
    guard var body = input.body
    else {
      throw RoutingError()
    }
    let boundaryValue = try BoundaryValueParser().parse(input)
    // Now we need to parse the multipart data into something more structured that
    // can be passed to the part parsers.
    let parts = try PartsParser(boundaryValue: boundaryValue).parse(&body)
    // Now we need to exhaustively parse each part.
    input.body = body
    return try partParsers.parse(parts)
  }
}

struct PartsParser: ParserPrinter {
  let boundaryValue: String
  
  var body: some ParserPrinter<Data, [PartData]> {
    Many {
      PartParser(boundaryValue: boundaryValue)
    } separator: {
      Whitespace(1, .vertical)
    } terminator: {
      ParsePrint {
        Whitespace(1, .vertical)
        From(DataToSubstring(encoding: .ascii)) {
          "--\(boundaryValue)--"
        }
      }
    }
  }
}

struct PartParser: ParserPrinter {
  let boundaryValue: String
  
  var body: some ParserPrinter<Data, PartData> {
    Parse(.memberwise(PartData.init)) {
      From(DataToSubstring(encoding: .ascii)) {
        "--\(boundaryValue)"
      }
      Whitespace(1, .vertical)
      PartHeaderFields()
      Optionally {
        PrefixUpTo("\n--\(boundaryValue)".data(using: .ascii)!)
      }
    }
  }
}

struct BoundaryValueParser: ParserPrinter {
  var body: some ParserPrinter<URLRequestData, String> {
    Parse(.string) {
      Headers {
        Field("Content-Type") {
          "multipart/form-data; boundary="
          Rest()
        }
      }
    }
  }
}

extension Multipart: ParserPrinter where PartParsers: ParserPrinter {
  public func print(_ output: PartParsers.Output, into input: inout URLRequestData) throws {
    let parts = try Array(partParsers.print(output))
    let partsData = try PartsParser(boundaryValue: boundaryValue).print(parts)
    input.body = partsData
    try BoundaryValueParser().print(boundaryValue, into: &input)
  }
}

public struct Part<Parsers: Parser>: Parser where Parsers.Input == PartData {
  let parsers: Parsers

  public init(@ParserBuilder<PartData> build: () -> Parsers) {
    self.parsers = build()
  }

  public func parse(_ input: inout ArraySlice<PartData>) throws -> Parsers.Output {
    guard let part = input.first else {
      throw RoutingError()
    }
    let output = try parsers.parse(part)
    input = input.dropFirst()
    return output
  }
}

extension Part: ParserPrinter where Parsers: ParserPrinter {
  public func print(_ output: Parsers.Output, into input: inout ArraySlice<PartData>) throws {
    var partData = PartData(headers: [:], body: nil)
    try parsers.print(output, into: &partData)
    input.prepend(partData)
  }
}

public struct PartData: Equatable {
  var headers: URLRequestData.Fields
  var body: Data?
}

/// Parses a multipart request body part's headers using field parsers.
public struct PartHeaders<FieldParsers: Parser>: Parser
where FieldParsers.Input == URLRequestData.Fields {
  let fieldParsers: FieldParsers

  public init(@ParserBuilder<URLRequestData.Fields> build: () -> FieldParsers) {
    self.fieldParsers = build()
  }

  public func parse(_ input: inout PartData) rethrows -> FieldParsers.Output {
    try fieldParsers.parse(&input.headers)
  }
}

extension PartHeaders: ParserPrinter where FieldParsers: ParserPrinter {
  public func print(_ output: FieldParsers.Output, into input: inout PartData) throws {
    try fieldParsers.print(output, into: &input.headers)
  }
}

struct PartHeaderFields: ParserPrinter {
  var body: some ParserPrinter<Data, URLRequestData.Fields> {
    Many {
      PartHeaderLine()
    } separator: {
      Whitespace(1, .vertical)
    } terminator: {
      Whitespace(2, .vertical)
    }
    .map(HeadersToFields())
  }
}

struct HeadersToFields: Conversion {
  func apply(_ input: [(String, Substring)]) throws -> URLRequestData.Fields {
    var fields: URLRequestData.Fields = [:]
    for (name, value) in input {
      fields[name, default: []].append(value)
    }
    return fields
  }
  
  func unapply(_ output: URLRequestData.Fields) throws -> [(String, Substring)] {
    var result: [(String, Substring)] = []
    for (name, values) in output {
      for value in values {
        if let value {
          result.append((name, value))
        }
      }
    }
    return result
  }
}

struct PartHeaderLine: ParserPrinter {
  var body: some ParserPrinter<Data, (String, Substring)> {
    From(DataToSubstring(encoding: .utf8)) {
      Not { Whitespace(1, .vertical) }
      PrefixUpTo(":").map(.string)
      ": "
      Prefix { $0 != "\n" }
    }
  }
}

/// Parses a request's body using a byte parser.
public struct PartBody<Bytes: Parser>: Parser where Bytes.Input == Data {
  let bytesParser: Bytes

  public init(@ParserBuilder<Data> _ bytesParser: () -> Bytes) {
    self.bytesParser = bytesParser()
  }

  /// Initializes a body parser from a byte conversion.
  ///
  /// Useful for parsing a request body in its entirety, for example as a JSON payload.
  ///
  /// ```swift
  /// struct Comment: Codable {
  ///   var author: String
  ///   var message: String
  /// }
  ///
  /// PartBody(.json(Comment.self))
  /// ```
  ///
  /// - Parameter bytesConversion: A conversion that transforms bytes into some other type.
  public init<C>(_ bytesConversion: C)
  where Bytes == Parsers.MapConversion<Parsers.ReplaceError<Rest<Data>>, C> {
    self.bytesParser = Rest().replaceError(with: .init()).map(bytesConversion)
  }

  /// Initializes a body parser that parses the body as data in its entirety.
  public init() where Bytes == Parsers.ReplaceError<Rest<Bytes.Input>> {
    self.bytesParser = Rest().replaceError(with: .init())
  }

  public func parse(_ input: inout PartData) throws -> Bytes.Output {
    guard var body = input.body
    else {
      throw RoutingError()
    }
    let output = try self.bytesParser.parse(&body)
    input.body = body
    return output
  }
}

extension PartBody: ParserPrinter where Bytes: ParserPrinter {
  public func print(_ output: Bytes.Output, into input: inout PartData) rethrows {
    input.body = try self.bytesParser.print(output)
  }
}

public struct DataToSubstring: Conversion {
  let encoding: String.Encoding
  
  public init(encoding: String.Encoding) {
    self.encoding = encoding
  }
  
  public func apply(_ output: Data) throws -> Substring {
    guard let input = String(data: output, encoding: encoding)
    else { throw ConversionError() }
    return Substring(input)
  }
  
  public func unapply(_ input: Substring) throws -> Data {
    guard let data = input.data(using: encoding)
    else { throw ConversionError() }
    return data
  }
  
  struct ConversionError: Error {}
}
