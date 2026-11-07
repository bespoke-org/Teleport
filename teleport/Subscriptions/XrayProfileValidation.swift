import CoreFoundation
import Foundation

nonisolated enum XrayProfileValidation {
    static func reject(_ section: String) -> XraySubscriptionProfileError {
        XraySubscriptionProfileError(reason: "Unsupported or invalid Xray \(section)")
    }

    static func keys(_ object: [String: Any], _ allowed: Set<String>, _ section: String) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw reject(section) }
    }

    static func object(_ value: Any?, _ section: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw reject(section) }
        return object
    }

    static func string(_ value: Any?, _ section: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else { throw reject(section) }
        return string
    }

    static func number(_ value: Any?, _ section: String, max: Double = Double(Int32.max), integer: Bool = true) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= max,
              !integer || number.doubleValue.rounded() == number.doubleValue else { throw reject(section) }
        return number.doubleValue
    }

    static func duration(_ value: Any, _ section: String) throws {
        guard let value = value as? String,
              value.range(of: "^(?:[0-9]+(?:\\.[0-9]+)?(?:ns|us|µs|ms|s|m|h))+$", options: .regularExpression) != nil else {
            throw reject(section)
        }
    }

    @discardableResult
    static func range(_ value: Any, _ section: String) throws -> ClosedRange<Int32> {
        if let value = value as? String {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({ Int32($0).map { $0 >= 0 } == true }),
                  Int32(parts[0])! <= Int32(parts.last!)! else { throw reject(section) }
            return Int32(parts[0])!...Int32(parts.last!)!
        }
        let number = Int32(try number(value, section))
        return number...number
    }

    static func xhttpExtra(_ value: Any, mode: String?) throws -> XrayJSONObject {
        let section = "XHTTP extra settings"
        guard ["", "auto", "packet-up", "stream-up", "stream-one"].contains(mode ?? "") else { throw reject(section) }
        var object = try object(value, section)
        let ranges: Set<String> = ["xPaddingBytes", "scMaxEachPostBytes", "scMinPostsIntervalMs", "scStreamUpServerSecs", "uplinkChunkSize"]
        let numbers: Set<String> = ["scMaxBufferedPosts"]
        let booleans: Set<String> = ["noSSEHeader", "noGRPCHeader", "xPaddingObfsMode"]
        let strings: Set<String> = ["xPaddingKey", "xPaddingHeader", "xPaddingPlacement", "xPaddingMethod", "uplinkHTTPMethod", "sessionKey", "sessionPlacement", "seqKey", "seqPlacement", "sessionIDKey", "sessionIDPlacement", "uplinkDataKey", "uplinkDataPlacement"]
        try keys(object, ranges.union(numbers).union(booleans).union(strings).union(["xmux"]), section)
        for (key, value) in object {
            if ranges.contains(key) { try range(value, section) }
            if numbers.contains(key) { _ = try number(value, section) }
            if strings.contains(key) {
                guard let string = value as? String, !string.contains("\r"), !string.contains("\n") else { throw reject(section) }
            }
            if booleans.contains(key) {
                guard let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { throw reject(section) }
            }
        }
        if let padding = object["xPaddingBytes"] {
            let bounds = try range(padding, section)
            guard bounds.lowerBound > 0 || bounds.upperBound == 0 else { throw reject(section) }
        }
        let options: [String: Set<String>] = [
            "xPaddingPlacement": ["", "cookie", "header", "query", "queryInHeader"],
            "xPaddingMethod": ["", "repeat-x", "tokenish"],
            "uplinkDataPlacement": ["", "auto", "body", "cookie", "header"],
            "sessionPlacement": ["", "path", "query", "header", "cookie"],
            "sessionIDPlacement": ["", "path", "query", "header", "cookie"],
            "seqPlacement": ["", "path", "query", "header", "cookie"],
        ]
        for (key, allowed) in options {
            if let value = object[key] as? String, !allowed.contains(value) { throw reject(section) }
        }
        if let placement = object["uplinkDataPlacement"] as? String, ["header", "cookie"].contains(placement), mode != "packet-up" {
            throw reject(section)
        }
        if let method = object["uplinkHTTPMethod"] as? String, !method.isEmpty {
            guard method.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil,
                  method.uppercased() != "GET" || mode == "packet-up" else { throw reject(section) }
        }
        if let xmux = object["xmux"] {
            let xmux = try self.object(xmux, section)
            let ranges: Set<String> = ["maxConcurrency", "maxConnections", "cMaxReuseTimes", "hMaxRequestTimes", "hMaxReusableSecs"]
            try keys(xmux, ranges.union(["hKeepAlivePeriod"]), section)
            for (key, value) in xmux {
                if ranges.contains(key) { try range(value, section) }
                else { _ = try number(value, section) }
            }
            let connections = try range(xmux["maxConnections"] ?? 0, section)
            let concurrency = try range(xmux["maxConcurrency"] ?? 0, section)
            guard connections.upperBound == 0 || concurrency.upperBound == 0 else { throw reject(section) }
        }
        for (legacy, current) in [("sessionKey", "sessionIDKey"), ("sessionPlacement", "sessionIDPlacement")] {
            if let value = object.removeValue(forKey: legacy) as? String, !value.isEmpty {
                guard object[current] == nil || object[current] as? String == value else { throw reject(section) }
                object[current] = value
            }
        }
        return try XrayJSONObject(object)
    }

    static func mux(_ object: [String: Any]) throws -> XrayJSONObject {
        let section = "multiplexing settings"
        try keys(object, ["enabled", "concurrency", "xudpConcurrency", "xudpProxyUDP443"], section)
        for key in ["concurrency", "xudpConcurrency"] {
            if let value = object[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue,
                      (-1...1024).contains(number.doubleValue) else { throw reject(section) }
            }
        }
        if let value = object["xudpProxyUDP443"] {
            guard let value = value as? String, ["", "reject", "allow", "skip"].contains(value) else { throw reject(section) }
        }
        return try XrayJSONObject(object)
    }
}
