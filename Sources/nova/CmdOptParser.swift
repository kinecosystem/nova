//
//  CmdOptParser2.swift
//  KinUtil
//
//  Created by Avi Shevin on 25/11/2018.
//

import Foundation

public enum CmdOptParseErrors: Error {
    case unknownOption(String, [Node])
    case ambiguousOption(String, [Node], [Node])
    case missingValue(Parameter, ParameterType, [Node])
    case invalidValue(Parameter, String, ParameterType, [Node])
    case invalidValueType(Parameter, String, ParameterType, [Node])
    case missingSubcommand([Node])
    case mutualExclusivityViolation(Node)
    case invalidParameterType(Parameter, ParameterType, [Node])
    case invalidRootType(Node)
}
typealias E = CmdOptParseErrors

public indirect enum Type {
    case string
    case int(ClosedRange<Int>?)
    case bool
    case date(format: String)
    case array(Type)
    case toggle
}

public enum ParameterType {
    case fixed
    case tagged
}

public struct Parameter {
    public let token: String
    let type: Type
    let description: String

    init(_ token: String, type: Type = .string, description: String = "") {
        self.token = token
        self.type = type
        self.description = description
    }
}

public struct Command {
    let token: String
    let description: String

    init(_ token: String, description: String = "") {
        self.token = token
        self.description = description
    }
}

public enum Node {
    case root(String, String, [Node])
    case parameter(Parameter, ParameterType)
    case command(Command, [Node])
}

public extension Node {
    static func parameter(_ token: String, type: Type = .string , description: String = "") -> Node {
        return .parameter(Parameter(token, type: type, description: description), .fixed)
    }

    static func option(_ token: String, type: Type = .string , description: String = "") -> Node {
        return .parameter(Parameter(token, type: type, description: description), .tagged)
    }

    static func command(_ token: String, description: String = "", _ children: [Node]) -> Node {
        return .command(Command(token, description: description), children)
    }
}

public extension Node {
    public var token: String {
        switch self {
        case .root(let token, _, _): return token
        case .parameter(let param, _): return param.token
        case .command(let cmd, _): return cmd.token
        }
    }

    func parameters(of type: ParameterType) -> [Node] {
        if case let .root(_, _, nodes) = self {
            return nodes.filter { if case let .parameter(_, t) = $0 { return t == type }; return false }
        }

        if case let .command(_, nodes) = self {
            return nodes.filter { if case let .parameter(_, t) = $0 { return t == type }; return false }
        }

        return []
    }

    var parameters: [Node] {
        return parameters(of: .fixed)
    }

    var options: [Node] {
        return parameters(of: .tagged)
    }

    var commands: [Node] {
        if case let .root(_, _, nodes) = self {
            return nodes.filter { if case .command = $0 { return true }; return false }
        }

        if case let .command(_, nodes) = self {
            return nodes.filter { if case .command = $0 { return true }; return false }
        }

        return []
    }
}

extension Node: CustomStringConvertible {
    public var description: String {
        switch self {
        case .root: return "root: " + token
        case .parameter: return "parameter: " + token
        case .command: return "command: " + token
        }
    }
}

public struct ParseResults {
    public let commandPath: [Node]
    public let parameterValues: [Any]
    public let optionValues: [String: Any]
    public let remainder: [String]
}

public extension ParseResults {
    subscript <T>(_ index: Int, _ type: T.Type) -> T? {
        return parameterValues[index] as? T
    }

    subscript <T>(_ name: String, _ type: T.Type) -> T? {
        return optionValues[name] as? T
    }

    func first<T>(as type: T.Type) -> T? {
        return parameterValues.first as? T
    }

    func last<T>(as type: T.Type) -> T? {
        return parameterValues.last as? T
    }
}

private let dateFormatter = DateFormatter()

private func prepare(_ args: [String]) -> ([String], [String]) {
    var remainder = [String]()
    if let index = args.firstIndex(of: "--"), index != args.endIndex - 1 {
        remainder = Array(args[(index + 1)...])
    }

    return (Array(args[0 ..< (args.firstIndex(of: "--") ?? args.endIndex)])
        .map { (a) -> [String] in
            if
                a.starts(with: "-"),
                let eqIndex = a.firstIndex(of: "="),
                eqIndex < a.index(before: a.endIndex)
            {
                return a.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map(String.init)
            }

            return [a]
        }.flatMap { $0 }, remainder)
}

public func parse(_ arguments: [String], node: Node) throws -> ParseResults {
    guard case let Node.root(_, _, nodes) = node else {
        throw E.invalidRootType(node)
    }

    var commandPath = [node]
    var parameterValues = [Any]()
    var optionValues = [String: Any]()

    var (arguments, remainder) = prepare(arguments)

    func value(for opt: Parameter, parameterType: ParameterType) throws -> Any? {
        func checkedValue(_ arg: String, for opt: Parameter, as type: Type) throws -> Any {
            let invalidValue = { E.invalidValue(opt, arg, parameterType, commandPath)}
            let invalidValueType = { E.invalidValue(opt, arg, parameterType, commandPath)}

            switch type {
            case .string:
                return arg

            case .int(let range):
                guard let i = Int(arg) else { throw invalidValueType() }

                guard range == nil || range!.contains(i) else { throw invalidValue() }

                return i

            case .bool:
                guard let b = Bool(arg) else { throw invalidValueType() }

                return b

            case .date(let format):
                dateFormatter.dateFormat = format
                guard let d = dateFormatter.date(from: arg) else { throw invalidValue() }

                return d

            default:
                throw invalidValueType()
            }
        }

        let arg = arguments.remove(at: 0)

        switch opt.type {
        case .array(let type):
            return try checkedValue(arg, for: opt, as: type)
        case .toggle:
            return nil
        default:
            return try checkedValue(arg, for: opt, as: opt.type)
        }
    }

    func optionMatch(_ arg: String, options: [Node]) throws -> Node? {
        var matches = [Node]()

        if arg.starts(with: "-") {
            // Exact match
            matches = options.filter {
                if case let .parameter(opt, _) = $0 {
                    return "-" + opt.token == arg || "--" + opt.token == arg
                }

                return false
            }

            // Prefix match
            if matches.isEmpty {
                matches = options.filter {
                    if case let .parameter(opt, _) = $0 {
                        return ("-" + opt.token).starts(with: arg) ||
                            ("--" + opt.token).starts(with: arg)
                    }

                    return false
                }
            }

            // notoggle match
            if matches.isEmpty {
                matches = options.filter {
                    if case let .parameter(opt, _) = $0, case .toggle = opt.type {
                        return ("-no" + opt.token).starts(with: arg) ||
                            ("--no" + opt.token).starts(with: arg)
                    }

                    return false
                }
            }

            if matches.count == 0 { throw E.unknownOption(arg, commandPath) }
            else if matches.count > 1 { throw E.ambiguousOption(arg, matches, commandPath) }
        }

        return matches.first
    }

    func _parse(node: Node) throws {
        let parameters = node.parameters
        let options = node.options
        let commands = node.commands

        guard parameters.isEmpty || commands.isEmpty else {
            throw E.mutualExclusivityViolation(node)
        }

        var done = false

        while !arguments.isEmpty && !done {
            let arg = arguments[0]

            if let match = try optionMatch(arg, options: options) {
                arguments.remove(at: 0)

                if case let .parameter(opt, _) = match {
                    if case .toggle = opt.type {
                        optionValues[opt.token] =
                            !arg.starts(with: "-no") && !arg.starts(with: "--no")
                    }
                    else {
                        guard !arguments.isEmpty else { throw E.missingValue(opt, .tagged, commandPath) }

                        if let v = try value(for: opt, parameterType: .tagged) {
                            if case .array = opt.type {
                                var a = optionValues[opt.token] as? [Any] ?? [Any]()
                                a.append(v)
                                optionValues[opt.token] = a
                            }
                            else {
                                optionValues[opt.token] = v
                            }
                        }
                    }
                }
            }
            else {
                for node in commands {
                    if case let .command(cmd, _) = node, cmd.token == arg {
                        arguments.remove(at: 0)

                        commandPath.append(node)

                        try _parse(node: node)
                    }
                }

                done = true
            }
        }

        for node in parameters {
            if case let .parameter(param, _) = node {
                if case .toggle = param.type {
                    throw E.invalidParameterType(param, .fixed, commandPath)
                }
                else {
                    guard !arguments.isEmpty else { throw E.missingValue(param, .fixed, commandPath) }

                    if let v = try value(for: param, parameterType: .fixed) {
                        parameterValues.append(v)
                    }
                }
            }
        }

        if !commands.isEmpty && !done {
            throw E.missingSubcommand(commandPath)
        }
    }

    try _parse(node: node)

    return ParseResults(commandPath: commandPath,
                        parameterValues: parameterValues,
                        optionValues: optionValues,
                        remainder: arguments + remainder)
}

public func usage(_ node: Node) -> String {
    return usage([node])
}

public func usage(_ path: [Node]) -> String {
    let root = path[0]
    let node = path[path.index(before: path.endIndex)]

    guard case Node.root = root else {
        return ""
    }

    let pathUsage = path.map { $0.token }.joined(separator: " ")

    var usage = "USAGE: \(pathUsage)"

    var optionlist = ""
    var commandlist = ""

    let options = node.options
    let commands = node.commands
    let parameters = node.parameters

    if !options.isEmpty {
        usage += " [options]"

        optionlist = "\n\nOPTIONS:"

        let width = options.map { $0.token.count }.reduce(0, max)

        options.forEach {
            if case let .parameter(val, _) = $0 {
                optionlist += "\n  -\(val.token)" +
                    String(repeating: " ", count: width - $0.token.count) + " : \(val.description)"
            }
        }
    }

    if !commands.isEmpty {
        usage += " <command>"

        commandlist = "\n\nSUBCOMMANDS:"

        let width = commands.map { $0.token.count }.reduce(0, max)

        commands.forEach {
            if case let .command(val) = $0 {
                commandlist += "\n  \($0.token)" +
                    String(repeating: " ", count: width - $0.token.count) + " : \(val.0.description)"
            }
        }
    }

    if !parameters.isEmpty {
        usage += " " + parameters.map({ "<\($0.token)>" }).joined(separator: " ")
    }

    return usage + optionlist + commandlist
}
