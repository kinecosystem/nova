//
//  CmdOptParser.swift
//  nova
//
//  Created by Avi Shevin on 25/11/2018.
//

import Foundation

public enum CmdOptParseErrors: Error {
    case unknownOption(String, [Command])
    case ambiguousOption(String, [_Parameter], [Command])
    case missingValue(_Parameter, [Command])
    case invalidValue(_Parameter, String, [Command])
    case invalidValueType(_Parameter, String, [Command])
    case missingSubcommand([Command])
    case invalidParameterType(_Parameter, [Command])
}
private typealias E = CmdOptParseErrors

public indirect enum ValueType {
    case string
    case int(ClosedRange<Int>?)    // If non-nil, values outside the range are rejected
    case double
    case bool                      // accepted strings: true/false
    case date(format: String)      // Dates that don't match the provided format string are rejected
    case array(ValueType)          // All cases except .array are supported
    case toggle                    // Only applies to Options.
    case custom((String) -> Any?)  // The closure should return nil if the value is rejected
}

private extension ValueType {
    var isToggle: Bool {
        switch self {
        case .toggle: return true
        default: return false
        }
    }
}

public final class Command {
    fileprivate typealias AddClosure = (inout [Any], Any) -> ()

    public let token: String

    fileprivate let description: String
    fileprivate let bindTarget: AnyObject?
    fileprivate var parameters = [_Parameter]()
    fileprivate var subcommands = [Command]()

    fileprivate let addToPath: AddClosure?

    public init(_ appName: String = CommandLine.arguments[0],
                description: String = "",
                bindTarget: AnyObject? = nil) {
        self.token = appName
        self.description = description
        self.bindTarget = bindTarget
        self.addToPath = nil
    }

    fileprivate init(token: String,
                     addToPath: @escaping AddClosure,
                     description: String = "",
                     bindTarget: AnyObject? = nil) {
        self.token = token
        self.description = description
        self.bindTarget = bindTarget
        self.addToPath = addToPath
    }
}

public extension Command {
    @discardableResult
    func command<Token>(_ command: Token,
                        bindTarget: AnyObject? = nil,
                        description: String = "",
                        configure: (Command) -> () = { _ in }) -> Self
        where Token: RawRepresentable, Token.RawValue == String
    {
        let addToPath: AddClosure = {
            $0.append(Token.init(rawValue: $1 as! String)!)
        }

        let node = Command(token: command.rawValue,
                           addToPath: addToPath,
                           description: description,
                           bindTarget: bindTarget ?? self.bindTarget)

        configure(node)
        subcommands.append(node)

        return self
    }

    @discardableResult
    func parameter(_ parameter: String,
                   type: ValueType = .string,
                   description: String = "") -> Self {
        parameters.append(Argument(parameter,
                                   type: type,
                                   binding: nil,
                                   description: description))

        return self
    }

    @discardableResult
    func parameter<R, V>(_ parameter: String,
                         type: ValueType = .string,
                         binding: ReferenceWritableKeyPath<R, V>,
                         description: String = "") -> Self {
        let b: ((Any) -> ())?
        if let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        parameters.append(Argument(parameter,
                                   type: type,
                                   binding: b,
                                   description: description))

        return self
    }

    @discardableResult
    func optional(_ parameter: String,
                  type: ValueType = .string,
                  description: String = "") -> Self {
        parameters.append(Optional(parameter,
                                   type: type,
                                   binding: nil,
                                   description: description))

        return self
    }

    @discardableResult
    func optional<R, V>(_ parameter: String,
                        type: ValueType = .string,
                        binding: ReferenceWritableKeyPath<R, V>,
                        description: String = "") -> Self {
        let b: ((Any) -> ())?
        if let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        parameters.append(Optional(parameter,
                                   type: type,
                                   binding: b,
                                   description: description))

        return self
    }

    @discardableResult
    func option(_ option: String,
                type: ValueType = .string,
                description: String = "") -> Self {
        parameters.append(Option(option,
                                 type: type,
                                 binding: nil,
                                 description: description))

        return self
    }

    @discardableResult
    func option<R, V>(_ option: String,
                      type: ValueType = .string,
                      binding: ReferenceWritableKeyPath<R, V>,
                      description: String = "") -> Self {
        let b: ((Any) -> ())?
        if let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        parameters.append(Option(option,
                                 type: type,
                                 binding: b,
                                 description: description))

        return self
    }
}

private extension Command {
    var arguments: [_Parameter] {
        return parameters
            .compactMap { $0 as? Argument }
    }

    var optionals: [_Parameter] {
        return parameters
            .compactMap { $0 as? Optional }
    }

    var options: [_Parameter] {
        return parameters
            .compactMap { $0 as? Option }
    }
}

public class _Parameter {
    public let token: String

    fileprivate let description: String
    fileprivate let type: ValueType
    fileprivate let binding: ((Any) -> ())?

    fileprivate var usageToken: String { return "" }

    fileprivate init(_ token: String,
                     type: ValueType,
                     binding: ((Any) -> ())? = nil,
                     description: String = "") {
        self.token = token
        self.description = description
        self.type = type
        self.binding = binding
    }
}

public final class Argument: _Parameter {
    override fileprivate var usageToken: String { return "<\(token)>" }
}

public final class Option: _Parameter {
    override fileprivate var usageToken: String { return "-\(token)" }
}

public final class Optional: _Parameter {
    override fileprivate var usageToken: String { return "[\(token)]" }
}

public struct ParseResults {
    public let commands: [Any]
    public let parameterValues: [Any]
    public let optionValues: [String: Any]
    public let remainder: [String]
}

private let dateFormatter = DateFormatter()

private func prepare(_ args: [String]) -> ([String], [String]) {
    let remainderIndex = args.firstIndex(of: "--") ?? args.endIndex
    let remainder = Array(args[remainderIndex ..< args.endIndex].dropFirst())

    return (Array(args[0 ..< remainderIndex])
        .map { $0.starts(with: "--") ? String($0.dropFirst()) : $0 }
        .map { a -> [String] in
            if
                a.starts(with: "-"),
                let eqIndex = a.firstIndex(of: "="),
                eqIndex < a.index(before: a.endIndex)
            {
                return a.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map(String.init)
            }

            return [a]
        }.flatMap { $0 }.reversed(), remainder)
}

@discardableResult
public func parse<S: Sequence>(_ arguments: S, node: Command) throws -> ParseResults
    where S.Element == String
{
    var commandPath = [node]
    var commands = [Any]()
    var parameterValues = [Any]()
    var optionValues = [String: Any]()

    var (arguments, remainder) = prepare(Array(arguments))

    func value(arg: String, for opt: _Parameter) throws -> Any? {
        func checkedValue(_ arg: String, for opt: _Parameter, as type: ValueType) throws -> Any {
            let invalidValue = E.invalidValue(opt, arg, commandPath)
            let invalidValueType = E.invalidValue(opt, arg, commandPath)

            switch type {
            case .string:
                return arg

            case .int(let range):
                guard let i = Int(arg) else { throw invalidValueType }

                guard range == nil || range!.contains(i) else { throw invalidValue }

                return i

            case .double:
                guard let d = Double(arg) else { throw invalidValueType }

                return d

            case .bool:
                guard let b = Bool(arg) else { throw invalidValueType }

                return b

            case .date(let format):
                dateFormatter.dateFormat = format
                guard let d = dateFormatter.date(from: arg) else { throw invalidValue }

                return d

            case .custom(let transform):
                guard let v = transform(arg) else { throw invalidValueType }

                return v

            default:
                fatalError("unhandled type")
            }
        }

        switch opt.type {
        case .array(let type):
            let args = arg.split(separator: ",")

            return try args.map {
                try checkedValue(String($0), for: opt, as: type)
            }
        case .toggle:
            return nil
        default:
            return try checkedValue(arg, for: opt, as: opt.type)
        }
    }

    func optionMatch(_ arg: String, options: [_Parameter]) throws -> _Parameter? {
        guard arg.starts(with: "-") else { return nil }

        var matches = [_Parameter]()

        let arg = arg.dropFirst()

        // Exact match
        matches = options.filter { $0.token == arg }

        // Prefix match
        if matches.isEmpty {
            matches = options.filter { $0.token.starts(with: arg) }
        }

        // notoggle match
        if matches.isEmpty {
            matches = options.filter {
                if $0.type.isToggle {
                    return ("no" + $0.token).starts(with: arg)
                }

                return false
            }
        }

        if matches.count == 0 { throw E.unknownOption("-" + arg, commandPath) }
        else if matches.count > 1 { throw E.ambiguousOption("-" + arg, matches, commandPath) }

        return matches.first
    }

    func _parse(node: Command) throws {
        precondition((node.arguments.isEmpty && node.optionals.isEmpty) || node.subcommands.isEmpty,
                     "A node must define either parameters or commands, but not both")

        var done = false

        while !arguments.isEmpty && !done {
            let arg = arguments.peek()

            if let match = try optionMatch(arg, options: node.options) {
                arguments.pop()

                if match.type.isToggle {
                    let v = !arg.starts(with: "-no")

                    optionValues[match.token] = v

                    if let binding = match.binding { binding(v) }
                }
                else {
                    guard !arguments.isEmpty else { throw E.missingValue(match, commandPath) }

                    if let v = try value(arg: arguments.pop(), for: match) {
                        optionValues[match.token] = v

                        if let binding = match.binding { binding(v) }
                    }
                }
            }
            else {
                for node in node.subcommands {
                    if node.token == arg {
                        arguments.pop()

                        commandPath.append(node)
                        node.addToPath!(&commands, node.token)

                        try _parse(node: node)
                    }
                }

                done = true
            }
        }

        for node in node.arguments + node.optionals {
            guard !node.type.isToggle else {
                fatalError("untagged parameters cannot be toggled")
            }

            if arguments.isEmpty {
                guard node is Optional else {
                    throw E.missingValue(node, commandPath)
                }

                break
            }

            if case .array = node.type {
                let args = arguments.pop().split(separator: ",")

                var values = [Any]()
                for arg in args {
                    if let v = try value(arg: String(arg), for: node) {
                        values.append(v)
                    }
                }
                parameterValues.append(values)

                if let binding = node.binding { binding(values) }
            }
            else {
                if let v = try value(arg: arguments.pop(), for: node) {
                    parameterValues.append(v)

                    if let binding = node.binding { binding(v) }
                }
            }
        }

        if !node.subcommands.isEmpty && !done {
            throw E.missingSubcommand(commandPath)
        }
    }

    try _parse(node: node)

    return ParseResults(commands: commands,
                        parameterValues: parameterValues,
                        optionValues: optionValues,
                        remainder: arguments + remainder)
}

private extension Array where Element == String {
    func peek() -> Element {
        return self[endIndex - 1]
    }

    @discardableResult
    mutating func pop() -> Element { return popLast()! }
}

public func usage(_ node: Command) -> String {
    return usage([node])
}

public func usage(_ path: [Command]) -> String {
    let node = path[path.index(before: path.endIndex)]

    let pathUsage = path.map { $0.token }.joined(separator: " ")

    var usage = "USAGE: \(pathUsage)"

    var optionlist = ""
    var commandlist = ""
    var paramsList = ""

    let options = node.options
    let commands = node.subcommands
    let parameters = node.arguments + node.optionals

    if !options.isEmpty {
        usage += " [options]"

        optionlist = "\n\nOPTIONS:"

        let width = options.map { $0.token.count }.reduce(0, max)

        options.forEach {
            optionlist += "\n  \($0.usageToken)" +
                String(repeating: " ", count: width - $0.token.count) + " : \($0.description)"
        }
    }

    if !commands.isEmpty {
        usage += " <command>"

        commandlist = "\n\nSUBCOMMANDS:"

        let width = commands.map { $0.token.count }.reduce(0, max)

        commands.forEach {
            commandlist += "\n  \($0.token)" +
                String(repeating: " ", count: width - $0.token.count) + " : \($0.description)"
        }
    }

    if !parameters.isEmpty {
        usage += " " + parameters.map({ $0.usageToken }).joined(separator: " ")

        paramsList = "\n\nPARAMETERS: <required> [optional]"

        let width = parameters.map { $0.token.count }.reduce(0, max)

        parameters.forEach {
            paramsList += "\n  \($0.usageToken)" +
                String(repeating: " ", count: width - $0.token.count) + " : \($0.description)"
        }
    }

    return usage + optionlist + paramsList + commandlist
}
