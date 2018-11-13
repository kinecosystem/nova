//
//  CmdOptParser.swift
//  KinUtil
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation

protocol Parameter {
    associatedtype OptType

    var handler: (OptType) -> () { get }

    func coerce(parameters: ArraySlice<String>) -> OptType?
}

public struct GenericParameter<G> {
    typealias OptType = G

    var handler: (OptType) -> ()
}

extension GenericParameter where G == Int {
    func coerce(parameters: ArraySlice<String>) -> OptType? {
        guard let p = parameters.last else {
            return nil
        }

        return Int(p)
    }
}

extension GenericParameter where G == String {
    func coerce(parameters: ArraySlice<String>) -> OptType? {
        return parameters.last
    }
}

public class Option {
    public let token: String
    public let shortDesc: String

    fileprivate(set) var consumes = 0

    init(_ token: String, shortDesc: String = "") {
        self.token = token
        self.shortDesc = shortDesc
    }
}

public extension Option {
    public static func string(_ token: String,
                              shortDesc: String = "",
                              handler: @escaping (String) -> ()) -> Option {
        return SingleOption(token, shortDesc: shortDesc, handler: handler)
    }

    public static func int(_ token: String,
                           shortDesc: String = "",
                           handler: @escaping (Int) -> ()) -> Option {
        return SingleOption(token, shortDesc: shortDesc, handler: handler)
    }
}

public final class ToggleOption: Option {
    var handler: (Bool) -> ()

    public init(_ token: String, shortDesc: String, handler: @escaping (Bool) -> ()) {
        self.handler = handler

        super.init(token, shortDesc: shortDesc)
    }
}

public final class SingleOption<T>: Option {
    let parameter: GenericParameter<T>

    public init(_ token: String, shortDesc: String, handler: @escaping (T) -> ()) {
        self.parameter = GenericParameter(handler: handler)

        super.init(token, shortDesc: shortDesc)

        consumes = 1
    }
}

public final class CmdParameter: Option {
    public typealias OptType = String

    let parameter: GenericParameter<String>

    public init(_ token: String, shortDesc: String = "", handler: @escaping (String) -> ()) {
        self.parameter = GenericParameter(handler: handler)

        super.init(token, shortDesc: shortDesc)
    }

    func coerce(parameters: ArraySlice<String>) -> String? {
        return parameters.last
    }
}

public final class CmdOptNode {
    public let token: String
    let subCommandRequired: Bool
    let shortDesc: String
    let longDesc: String?

    weak var parent: CmdOptNode?

    private(set) var commands = [CmdOptNode]()
    private(set) var options = [Option]()
    private(set) var parameters = [CmdParameter]()

    public init(token: String,
                subCommandRequired: Bool = false,
                shortDesc: String = "",
                longDesc: String? = nil) {
        self.token = token
        self.subCommandRequired = subCommandRequired
        self.shortDesc = shortDesc
        self.longDesc = longDesc
    }

    @discardableResult
    public func add(commands: [CmdOptNode]) -> CmdOptNode {
        commands.forEach { $0.parent = self }

        self.commands = commands

        return self
    }

    @discardableResult
    public func add(options: [Option]) -> CmdOptNode {
        self.options = options

        return self
    }

    @discardableResult
    public func add(parameters: [CmdParameter]) -> CmdOptNode {
        self.parameters = parameters

        return self
    }
}

public enum CmdOptParserErrors: Error {
    case unrecognizedOption(String, CmdOptNode)
    case ambiguousOption(String, [String], CmdOptNode)
    case missingOptionParameter(Option, CmdOptNode)
    case missingCmdParameter(CmdOptNode)
    case missingSubCommand(CmdOptNode)
}
private typealias E = CmdOptParserErrors

public func parse(_ arguments: [String],
                  rootNode: CmdOptNode) throws -> ([String], [String]) {
    var cmdPath = [String]()

    let splits = arguments.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: true)

    let remainder = try _parse(arguments: splits[0][...], node: rootNode, path: &cmdPath)

    return (cmdPath, Array(remainder + (splits.count > 1 ? splits[1] : [])))
}

private func _parse(arguments: ArraySlice<String>,
                    node: CmdOptNode, path: inout [String]) throws -> ArraySlice<String> {
    var arguments = arguments
    
    var shouldConsume = 0
    var index: Int = arguments.startIndex
    let depth = path.count

    for i in arguments.indices {
        index += 1

        if shouldConsume > 0 {
            shouldConsume -= 1
            continue
        }

        var argument = arguments[i]

        let optHandler = { (opt: Option) in
            shouldConsume = opt.consumes

            if i + shouldConsume >= arguments.endIndex {
                throw E.missingOptionParameter(opt, node)
            }

            // Special support for toggles
            if let opt = opt as? ToggleOption {
                opt.handler(true)
            }
            else {
                if
                    let o = opt as? SingleOption<String>,
                    let v = o.parameter.coerce(parameters: arguments[(i + 1) ... (i + shouldConsume)])
                {
                    o.parameter.handler(v)
                }
            }
        }

        if argument.starts(with: "-") {
            while argument.starts(with: "-") { argument = String(argument.dropFirst()) }

            if argument.firstIndex(of: "=") != argument.index(before: argument.endIndex) {
                let split = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

                argument = String(split[0])
                arguments.insert(String(split[1]), at: i + 1)
            }

            // Exact match
            if let opt = node.options.filter({ $0.token == argument }).last {
                try optHandler(opt)
            }
                // Check for inverted toggles
            else if let opt = node.options.filter({ "no\($0.token)" == argument }).last as? ToggleOption {
                opt.handler(false)
            }
            else {
                // Partial match
                let opts = node.options.filter({ $0.token.starts(with: argument) })

                guard opts.count == 1 else {
                    if opts.isEmpty {
                        throw E.unrecognizedOption(arguments[i], node)
                    }
                    else {
                        throw E.ambiguousOption(arguments[i], opts.map { $0.token }, node)
                    }
                }

                try optHandler(opts[0])
            }
        }
        else {
            if let node = node.commands.filter({ $0.token == argument }).last {
                path.append(argument)

                let paramCount = node.parameters.count

                if paramCount >= arguments.count {
                    throw E.missingCmdParameter(node)
                }

                for pi in 0 ..< paramCount {
                    let param = node.parameters[pi]
                    if let p = param.parameter.coerce(parameters: arguments[(pi + i + 1)...]) {
                        param.parameter.handler(p)
                    }
                }

                return try _parse(arguments: arguments[(i + 1 + paramCount)...],
                                  node: node,
                                  path: &path)
            }

            index -= 1
            
            break
        }
    }

    if node.subCommandRequired && path.count <= depth {
        throw E.missingSubCommand(node)
    }

    return arguments[index...]
}

public func help(_ node: CmdOptNode) -> String {
    var path = [ node.token ]

    var n = node
    while let parent = n.parent {
        path.append(parent.token)
        n = parent
    }

    var help = "OVERVIEW: \(node.longDesc ?? node.shortDesc)\n\nUSAGE: " +
        path.reversed().joined(separator: " ")

    if !node.parameters.isEmpty {
        help += " " + node.parameters.map({ "<\($0.token)>" }).joined(separator: " ")
    }

    if !node.options.isEmpty {
        help += " [options]"
    }

    if !node.commands.isEmpty {
        help += node.subCommandRequired ? " <cmd>" : " [cmd]"

        if !node.parameters.isEmpty {
            help += " <parameters>"
        }
    }

    if !node.options.isEmpty {
        help += "\n\nOPTIONS:\n"

        let width = node.options.map { $0.token.count }.reduce(0, max)

        node.options.forEach {
            help += "  -" +
                $0.token +
                String(repeating: " ", count: width - $0.token.count) + " : \($0.shortDesc)\n"
        }
    }
    else {
        help += "\n"
    }

    if !node.commands.isEmpty {
        help += "\nSUBCOMMANDS:\n"

        let width = node.commands.map { $0.token.count }.reduce(0, max)

        node.commands.forEach {
            help += "  " +
                $0.token +
                String(repeating: " ", count: width - $0.token.count) + " : \($0.shortDesc)\n"
        }
    }

    return help
}
