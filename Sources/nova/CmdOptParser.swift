//
//  CmdOptParser2.swift
//  KinUtil
//
//  Created by Avi Shevin on 25/11/2018.
//

import Foundation

public enum CmdOptParseErrors: Error {
    case unknownOption(String, [NodeParent])
    case ambiguousOption(String, [Node], [NodeParent])
    case missingValue(Parameter, ParameterType, [NodeParent])
    case invalidValue(Parameter, String, ParameterType, [NodeParent])
    case invalidValueType(Parameter, String, ParameterType, [NodeParent])
    case missingSubcommand([NodeParent])
    case mutualExclusivityViolation(Node)
    case invalidParameterType(Parameter, ParameterType, [NodeParent])
}
private typealias E = CmdOptParseErrors

public indirect enum Type {
    case string
    case int(ClosedRange<Int>?)
    case double
    case bool
    case date(format: String)
    case array(Type)
    case toggle
    case custom((String) -> Any?)
}

public enum ParameterType {
    case fixed
    case optional
    case tagged
}

public struct Parameter {
    let token: String
    let type: Type
    let description: String
    let binding: ((Any) -> ())?

    init(_ token: String, type: Type = .string, description: String = "", binding: ((Any) -> ())? = nil) {
        self.token = token
        self.type = type
        self.description = description
        self.binding = binding
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

public protocol Node: AnyObject {
    var token: String { get }
}

public protocol NodeParent: Node {
    var bindTarget: AnyObject? { get }
    var children: [Node] { get set }
}

extension NodeParent {
    @discardableResult
    func command(_ command: String,
                 description: String = "",
                 bindTarget: AnyObject? = nil,
                 configure: (CommandNode) -> () = { _ in }) -> Self {
        let node = CommandNode(command: Command(command, description: description),
                               bindTarget: bindTarget ?? self.bindTarget)

        configure(node)
        children.append(node)

        return self
    }

    @discardableResult
    func parameter(_ parameter: String,
                   type: Type = .string,
                   description: String = "") -> Self {
        children.append(ParameterNode(parameter: Parameter(parameter, type: type, description: description, binding: nil),
                                      type: .fixed))

        return self
    }

    @discardableResult
    func parameter<R, V>(_ parameter: String,
                         type: Type = .string,
                         description: String = "",
                         binding: ReferenceWritableKeyPath<R, V>? = nil) -> Self {
        let b: ((Any) -> ())?
        if let binding = binding, let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        children.append(ParameterNode(parameter: Parameter(parameter, type: type, description: description, binding: b),
                                      type: .fixed))

        return self
    }

    @discardableResult
    func optional(_ parameter: String,
                  type: Type = .string,
                  description: String = "") -> Self {
        children.append(ParameterNode(parameter: Parameter(parameter, type: type, description: description, binding: nil),
                                      type: .optional))

        return self
    }

    @discardableResult
    func optional<R, V>(_ parameter: String,
                        type: Type = .string,
                        description: String = "",
                        binding: ReferenceWritableKeyPath<R, V>? = nil) -> Self {
        let b: ((Any) -> ())?
        if let binding = binding, let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        children.append(ParameterNode(parameter: Parameter(parameter, type: type, description: description, binding: b),
                                      type: .optional))

        return self
    }

    @discardableResult
    func option(_ option: String,
                type: Type = .string,
                description: String = "") -> Self {
        children.append(ParameterNode(parameter: Parameter(option, type: type, description: description, binding: nil),
                                      type: .tagged))

        return self
    }

    @discardableResult
    func option<R, V>(_ option: String,
                      type: Type = .string,
                      description: String = "",
                      binding: ReferenceWritableKeyPath<R, V>) -> Self {
        let b: ((Any) -> ())?
        if let target = bindTarget as? R {
            b = { target[keyPath: binding] = $0 as! V }
        }
        else { b = nil }

        children.append(ParameterNode(parameter: Parameter(option, type: type, description: description, binding: b),
                                      type: .tagged))

        return self
    }
}

extension NodeParent {
    var parameters: [Node] {
        return children.filter { ($0 as? ParameterNode)?.type == .fixed }
    }

    var optionals: [Node] {
        return children.filter { ($0 as? ParameterNode)?.type == .optional }
    }

    var options: [Node] {
        return children.filter { ($0 as? ParameterNode)?.type == .tagged }
    }

    var commands: [NodeParent] {
        return children
            .filter { $0 is CommandNode || $0 is Root }
            .compactMap { $0 as? NodeParent }
    }
}

public final class Root: NodeParent {
    let appName: String
    let description: String
    public let bindTarget: AnyObject?
    public var children = [Node]()

    public var token: String { return appName }

    init(_ appName: String, description: String = "", bindTarget: AnyObject? = nil) {
        self.appName = appName
        self.description = description
        self.bindTarget = bindTarget
    }
}

final class ParameterNode: Node {
    let parameter: Parameter
    let type: ParameterType

    var token: String { return parameter.token }

    init(parameter: Parameter, type: ParameterType) {
        self.parameter = parameter
        self.type = type
    }
}

extension ParameterNode {
    var usageToken: String {
        switch type {
        case .fixed: return "<" + token + ">"
        case .optional: return "[" + token + "]"
        case .tagged: return "-" + token
        }
    }
}

final class CommandNode: NodeParent {
    let command: Command
    let bindTarget: AnyObject?
    var children = [Node]()

    init(command: Command, bindTarget: AnyObject?) {
        self.command = command
        self.bindTarget = bindTarget
    }
}

extension CommandNode {
    var token: String { return command.token }
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
        }.flatMap { $0 }, remainder)
}

@discardableResult
public func parse(_ arguments: [String], node: Root) throws -> ParseResults {
    var commandPath: [NodeParent] = [node]
    var parameterValues = [Any]()
    var optionValues = [String: Any]()

    var (arguments, remainder) = prepare(arguments)

    func value(arg: String, for opt: Parameter, parameterType: ParameterType) throws -> Any? {
        func checkedValue(_ arg: String, for opt: Parameter, as type: Type) throws -> Any {
            let invalidValue = { E.invalidValue(opt, arg, parameterType, commandPath) }
            let invalidValueType = { E.invalidValue(opt, arg, parameterType, commandPath) }

            switch type {
            case .string:
                return arg

            case .int(let range):
                guard let i = Int(arg) else { throw invalidValueType() }

                guard range == nil || range!.contains(i) else { throw invalidValue() }

                return i

            case .double:
                guard let d = Double(arg) else { throw invalidValueType() }

                return d

            case .bool:
                guard let b = Bool(arg) else { throw invalidValueType() }

                return b

            case .date(let format):
                dateFormatter.dateFormat = format
                guard let d = dateFormatter.date(from: arg) else { throw invalidValue() }

                return d

            case .custom(let block):
                guard let v = block(arg) else { throw invalidValueType() }

                return v

            default:
                throw invalidValueType()
            }
        }

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
            let arg = arg.dropFirst()

            // Exact match
            matches = options.filter {
                return $0.token == arg
            }

            // Prefix match
            if matches.isEmpty {
                matches = options.filter {
                    return $0.token.starts(with: arg)
                }
            }

            // notoggle match
            if matches.isEmpty {
                matches = options.filter {
                    if let type = ($0 as? ParameterNode)?.parameter.type, case .toggle = type {
                        return ("no" + $0.token).starts(with: arg)
                    }

                    return false
                }
            }

            if matches.count == 0 { throw E.unknownOption("-" + arg, commandPath) }
            else if matches.count > 1 { throw E.ambiguousOption("-" + arg, matches, commandPath) }
        }

        return matches.first
    }

    func _parse(node: NodeParent) throws {
        let parameters = node.parameters
        let optionals = node.optionals
        let options = node.options
        let commands = node.commands

        precondition(parameters.isEmpty || commands.isEmpty,
                     "A node must define either parameters or commands, but not both")

        var done = false

        while !arguments.isEmpty && !done {
            let arg = arguments[0]

            if let match = try optionMatch(arg, options: options) {
                arguments.remove(at: 0)

                if let opt = (match as? ParameterNode)?.parameter {
                    if case .toggle = opt.type {
                        let v = !arg.starts(with: "-no")

                        optionValues[opt.token] = v

                        if let binding = opt.binding { binding(v) }
                    }
                    else {
                        guard !arguments.isEmpty else { throw E.missingValue(opt, .tagged, commandPath) }

                        if let v = try value(arg: arguments.remove(at: 0), for: opt, parameterType: .tagged) {
                            if case .array = opt.type {
                                var a = optionValues[opt.token] as? [Any] ?? [Any]()
                                a.append(v)
                                optionValues[opt.token] = a

                                if let binding = opt.binding { binding(a) }
                            }
                            else {
                                optionValues[opt.token] = v

                                if let binding = opt.binding { binding(v) }
                            }
                        }
                    }
                }
            }
            else {
                for node in commands {
                    if let cmd = node as? CommandNode, cmd.token == arg {
                        arguments.remove(at: 0)

                        commandPath.append(node)

                        try _parse(node: node)
                    }
                }

                done = true
            }
        }

        for node in parameters + optionals {
            if let node = node as? ParameterNode {
                let param = node.parameter

                if case .toggle = param.type {
                    throw E.invalidParameterType(param, node.type, commandPath)
                }
                else {
                    if arguments.isEmpty {
                        if node.type == .optional {
                            break
                        }

                        throw E.missingValue(param, node.type, commandPath)
                    }

                    if case .array = param.type {
                        let args = arguments.remove(at: 0).split(separator: ",")

                        var values = [Any]()
                        for arg in args {
                            if let v = try value(arg: String(arg), for: param, parameterType: node.type) {
                                values.append(v)
                            }
                        }
                        parameterValues.append(values)

                        if let binding = param.binding { binding(values) }
                    }
                    else {
                        if let v = try value(arg: arguments.remove(at: 0), for: param, parameterType: node.type) {
                            parameterValues.append(v)

                            if let binding = param.binding { binding(v) }
                        }
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

public func usage(_ node: NodeParent) -> String {
    return usage([node])
}

public func usage(_ path: [NodeParent]) -> String {
    let root = path[0]
    let node = path[path.index(before: path.endIndex)]

    guard root is Root else {
        return ""
    }

    let pathUsage = path.map { $0.token }.joined(separator: " ")

    var usage = "USAGE: \(pathUsage)"

    var optionlist = ""
    var commandlist = ""

    let options = node.options
    let commands = node.commands
    let parameters = node.parameters + node.optionals

    if !options.isEmpty {
        usage += " [options]"

        optionlist = "\n\nOPTIONS:"

        let width = options.map { $0.token.count }.reduce(0, max)

        options.forEach {
            if let val = $0 as? ParameterNode {
                optionlist += "\n  \(val.usageToken)" +
                    String(repeating: " ", count: width - $0.token.count) + " : \(val.parameter.description)"
            }
        }
    }

    if !commands.isEmpty {
        usage += " <command>"

        commandlist = "\n\nSUBCOMMANDS:"

        let width = commands.map { $0.token.count }.reduce(0, max)

        commands.forEach {
            if let val = $0 as? CommandNode {
                commandlist += "\n  \($0.token)" +
                    String(repeating: " ", count: width - $0.token.count) + " : \(val.command.description)"
            }
        }
    }

    if !parameters.isEmpty {
        usage += " " + parameters.map({ ($0 as! ParameterNode).usageToken }).joined(separator: " ")
    }

    return usage + optionlist + commandlist
}
