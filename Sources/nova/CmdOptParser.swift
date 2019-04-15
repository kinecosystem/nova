//
//  CmdOptParser2.swift
//  KinUtil
//
//  Created by Avi Shevin on 25/11/2018.
//

import Foundation

public enum CmdOptParseErrors: Error {
    case unknownOption(String, [ParentNode])
    case ambiguousOption(String, [Node], [ParentNode])
    case missingValue(Parameter, [ParentNode])
    case invalidValue(Parameter, String, [ParentNode])
    case invalidValueType(Parameter, String, [ParentNode])
    case missingSubcommand([ParentNode])
    case invalidParameterType(Parameter, [ParentNode])
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

extension ValueType {
    var isToggle: Bool {
        switch self {
        case .toggle: return true
        default: return false
        }
    }
}

public enum ParameterType {
    case fixed
    case optional
    case tagged
}

public protocol Node: AnyObject {
    var token: String { get }
    var description: String { get }
}

public protocol ParentNode: Node {
    var bindTarget: AnyObject? { get }
    var children: [Node] { get set }
}

public extension ParentNode {
    @discardableResult
    func command(_ command: String,
                 bindTarget: AnyObject? = nil,
                 description: String = "",
                 configure: (ParentNode) -> () = { _ in }) -> Self {
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
        children.append(Parameter(parameter,
                                      type: type,
                                      binding: nil,
                                      description: description,
                                      parameterType: .fixed))

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

        children.append(Parameter(parameter,
                                      type: type,
                                      binding: b,
                                      description: description,
                                      parameterType: .fixed))

        return self
    }

    @discardableResult
    func optional(_ parameter: String,
                  type: ValueType = .string,
                  description: String = "") -> Self {
        children.append(Parameter(parameter,
                                      type: type,
                                      binding: nil,
                                      description: description,
                                      parameterType: .optional))

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

        children.append(Parameter(parameter,
                                      type: type,
                                      binding: b,
                                      description: description,
                                      parameterType: .optional))

        return self
    }

    @discardableResult
    func option(_ option: String,
                type: ValueType = .string,
                description: String = "") -> Self {
        children.append(Parameter(option,
                                      type: type,
                                      binding: nil,
                                      description: description,
                                      parameterType: .tagged))

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

        children.append(Parameter(option,
                                      type: type,
                                      binding: b,
                                      description: description,
                                      parameterType: .tagged))

        return self
    }
}

fileprivate extension ParentNode {
    var parameters: [Parameter] {
        return children
            .compactMap { $0 as? Parameter }
            .filter { $0.parameterType == .fixed }
    }

    var optionals: [Parameter] {
        return children
            .compactMap { $0 as? Parameter }
            .filter { $0.parameterType == .optional }
    }

    var options: [Parameter] {
        return children
            .compactMap { $0 as? Parameter }
            .filter { $0.parameterType == .tagged }
    }

    var commands: [ParentNode] {
        return children
            .compactMap { $0 as? ParentNode }
            .filter { $0 is Command || $0 is Root }
    }
}

public final class Root: ParentNode {
    let appName: String
    public let description: String
    public let bindTarget: AnyObject?
    public var children = [Node]()

    public var token: String { return appName }

    public init(_ appName: String, description: String = "", bindTarget: AnyObject? = nil) {
        self.appName = appName
        self.description = description
        self.bindTarget = bindTarget
    }
}

public final class Parameter: Node {
    public let token: String
    public let type: ValueType
    public let parameterType: ParameterType
    public let description: String
    let binding: ((Any) -> ())?

    fileprivate init(_ token: String, type: ValueType, binding: ((Any) -> ())? = nil, description: String = "", parameterType: ParameterType) {
        self.token = token
        self.type = type
        self.binding = binding
        self.parameterType = parameterType
        self.description = description
    }
}

extension Parameter {
    var usageToken: String {
        switch parameterType {
        case .fixed: return "<" + token + ">"
        case .optional: return "[" + token + "]"
        case .tagged: return "-" + token
        }
    }
}

public final class Command: ParentNode {
    public let token: String
    public let bindTarget: AnyObject?
    public let description: String
    public var children = [Node]()

    fileprivate init(_ token: String, description: String = "", bindTarget: AnyObject?) {
        self.token = token
        self.description = description
        self.bindTarget = bindTarget
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
public func parse<S: Sequence>(_ arguments: S, node: Root) throws -> ParseResults
    where S.Element == String
{
    var commandPath: [ParentNode] = [node]
    var parameterValues = [Any]()
    var optionValues = [String: Any]()

    var (arguments, remainder) = prepare(Array(arguments))

    func value(arg: String, for opt: Parameter) throws -> Any? {
        func checkedValue(_ arg: String, for opt: Parameter, as type: ValueType) throws -> Any {
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

    func optionMatch(_ arg: String, options: [Parameter]) throws -> Parameter? {
        guard arg.starts(with: "-") else { return nil }

        var matches = [Parameter]()

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

    func _parse(node: ParentNode) throws {
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
                guard node.parameterType == .optional else {
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

public func usage(_ node: ParentNode) -> String {
    return usage([node])
}

public func usage(_ path: [ParentNode]) -> String {
    let root = path[0]
    let node = path[path.index(before: path.endIndex)]

    guard root is Root else {
        return ""
    }

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
