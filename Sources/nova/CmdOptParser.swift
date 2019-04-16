//
//  CmdOptParser2.swift
//  KinUtil
//
//  Created by Avi Shevin on 25/11/2018.
//

import Foundation

public enum CmdOptParseErrors: Error {
    case unknownOption(String, [_ParentNode])
    case ambiguousOption(String, [_Node], [_ParentNode])
    case missingValue(_Parameter, [_ParentNode])
    case invalidValue(_Parameter, String, [_ParentNode])
    case invalidValueType(_Parameter, String, [_ParentNode])
    case missingSubcommand([_ParentNode])
    case invalidParameterType(_Parameter, [_ParentNode])
}
private typealias E = CmdOptParseErrors

public indirect enum ValueType {
    case string
    case int(ClosedRange<Int>?)
    case double
    case bool
    case date(format: String)
    case array(ValueType)
    case toggle
    case custom((String) -> Any?)
}

private extension ValueType {
    var isToggle: Bool {
        switch self {
        case .toggle: return true
        default: return false
        }
    }
}

public class _Node {
    public let token: String
    fileprivate let description: String

    fileprivate init(token: String, description: String) {
        self.token = token
        self.description = description
    }
}

public class _ParentNode: _Node {
    fileprivate let bindTarget: AnyObject?
    fileprivate var children = [_Node]()

    fileprivate init(token: String, description: String, bindTarget: AnyObject?) {
        self.bindTarget = bindTarget

        super.init(token: token, description: description)
    }
}

public extension _ParentNode {
    @discardableResult
    func command(_ command: String,
                 bindTarget: AnyObject? = nil,
                 description: String = "",
                 configure: (_ParentNode) -> () = { _ in }) -> Self {
        let node = Command(command,
                               description: description,
                               bindTarget: bindTarget ?? self.bindTarget)

        configure(node)
        children.append(node)

        return self
    }

    @discardableResult
    func parameter(_ parameter: String,
                   type: ValueType = .string,
                   description: String = "") -> Self {
        children.append(Argument(parameter,
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

        children.append(Argument(parameter,
                                 type: type,
                                 binding: b,
                                 description: description))

        return self
    }

    @discardableResult
    func optional(_ parameter: String,
                  type: ValueType = .string,
                  description: String = "") -> Self {
        children.append(Optional(parameter,
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

        children.append(Optional(parameter,
                                 type: type,
                                 binding: b,
                                 description: description))

        return self
    }

    @discardableResult
    func option(_ option: String,
                type: ValueType = .string,
                description: String = "") -> Self {
        children.append(Option(option,
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

        children.append(Option(option,
                               type: type,
                               binding: b,
                               description: description))

        return self
    }
}

private extension _ParentNode {
    var parameters: [_Parameter] {
        return children
            .compactMap { $0 as? Argument }
    }

    var optionals: [_Parameter] {
        return children
            .compactMap { $0 as? Optional }
    }

    var options: [_Parameter] {
        return children
            .compactMap { $0 as? Option }
    }

    var commands: [_ParentNode] {
        return children
            .compactMap { $0 as? Command }
    }
}

public final class Command: _ParentNode {
    public init(_ appName: String, description: String = "", bindTarget: AnyObject? = nil) {
        super.init(token: appName, description: description, bindTarget: bindTarget)
    }
}

public class _Parameter: _Node {
    fileprivate let type: ValueType
    fileprivate let binding: ((Any) -> ())?

    fileprivate var usageToken: String { return "" }

    fileprivate init(_ token: String, type: ValueType, binding: ((Any) -> ())? = nil, description: String = "") {
        self.type = type
        self.binding = binding

        super.init(token: token, description: description)
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
    public let commandPath: [_Node]
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
    var commandPath: [_ParentNode] = [node]
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

    func _parse(node: _ParentNode) throws {
        let parameters = node.parameters
        let optionals = node.optionals
        let options = node.options
        let commands = node.commands

        precondition(parameters.isEmpty || commands.isEmpty,
                     "A node must define either parameters or commands, but not both")

        var done = false

        while !arguments.isEmpty && !done {
            let arg = arguments.peek()

            if let match = try optionMatch(arg, options: options) {
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
                for node in commands {
                    if let cmd = node as? Command, cmd.token == arg {
                        arguments.pop()

                        commandPath.append(node)

                        try _parse(node: node)
                    }
                }

                done = true
            }
        }

        for node in parameters + optionals {
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

private extension Array where Element == String {
    func peek() -> Element {
        return self[endIndex - 1]
    }

    @discardableResult
    mutating func pop() -> Element { return popLast()! }
}

public func usage(_ node: _ParentNode) -> String {
    return usage([node])
}

public func usage(_ path: [_ParentNode]) -> String {
    let node = path[path.index(before: path.endIndex)]

    let pathUsage = path.map { $0.token }.joined(separator: " ")

    var usage = "USAGE: \(pathUsage)"

    var optionlist = ""
    var commandlist = ""
    var paramsList = ""

    let options = node.options
    let commands = node.commands
    let parameters = node.parameters + node.optionals

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
            if let val = $0 as? Command {
                commandlist += "\n  \($0.token)" +
                    String(repeating: " ", count: width - $0.token.count) + " : \(val.description)"
            }
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
