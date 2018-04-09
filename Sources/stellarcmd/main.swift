//
//  main.swift
//  stellar
//
//  Created by Kin Foundation.
//  Copyright © 2018 Kin Foundation. All rights reserved.
//

import Foundation
import StellarKit
import Sodium
import KinUtil

struct Configuration: Decodable {
    let xlm_issuer: String
    let horizon_url: URL
    let network_id: String
}

struct Command: Decodable {
    let cmd: String
    let continueOnError: Bool?

    let account: String?
    let seed: String?
    let asset_code: String?
    let asset_issuer: String?
    let destination: String?
    let amount: Int64?
}

struct StellarAccount: Account {
    var publicKey: String? {
        return StellarKit.KeyUtils.base32(publicKey: keyPair.publicKey)
    }

    let keyPair: Sign.KeyPair

    init(seedStr: String) {
        keyPair = KeyUtils.keyPair(from: seedStr)!

        let secretKey = keyPair.secretKey

        sign = { message in
            return try KeyUtils.sign(message: message,
                                     signingKey: secretKey)
        }
    }

    var sign: ((Data) throws -> Data)?

    init() {
        self.init(seedStr: StellarKit.KeyUtils.base32(seed: KeyUtils.seed()!))
    }
}

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String

    var description: String {
        return message
    }
}

var node: Stellar.Node!
var xlmIssuer: StellarAccount!

func printUsage() {
    let usage = """
    stellar CMD [ARGS]

    Commands:
        info <public key>
        create <public key>
        trust <seed> <asset code> <asset issuer public key>
        pay <seed> <public key> <amount> [<asset code> <asset issuer public key>]

        script <path to script>
    """

    print(usage)
}

func printConfig() {
    print(
        """
        Configuration:
            XLM Issuer: \(xlmIssuer.publicKey!)
            Node: \(node.baseURL) [\(node.networkId)]

        """
    )
}

func info(account: String) -> Promise<String> {
    return Stellar.accountDetails(account: account, node: node)
        .then({
            print($0)

            return Promise<String>().signal($0.description)
        })
        .transformError({
            return ErrorMessage(message: "Received error retrieving account info: \($0)")
        })
}

func create(account: String) -> Promise<String> {
    return Stellar.sequence(account: xlmIssuer.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let tx = Transaction(sourceAccount: xlmIssuer.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: [StellarKit.Operation.createAccount(destination: account,
                                                                                 balance: 100 * 10000000)])

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: xlmIssuer,
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .then({ _ in
            print("Created account for: \(account)")
        })
        .transformError({
            return ErrorMessage(message: "Received error while creating account: \($0)")
        })
}

func trust(of asset: Asset, by account: Account) -> Promise<String> {
    return Stellar.trust(asset: asset, account: account, node: node)
        .then({ _ in
            print("Account \(account.publicKey!) trusted asset: \(asset.assetCode)")
        })
        .transformError({
            return ErrorMessage(message: "Received error while trusting asset: \($0)")
        })
}

func pay(from source: Account, to destination: String, amount: Int64, asset: Asset?) -> Promise<String> {
    if let asset = asset {
        return Stellar.payment(source: source, destination: destination, amount: amount, asset: asset, node: node)
            .then({ _ in
                let amount = Decimal(Double(amount) / 10_000_000)
                print("Sent payment of \(amount) \(asset.assetCode) to \(destination)")
            })
            .transformError({
                return ErrorMessage(message: "Received error while sending payment: \($0)")
            })
    }
    else {
        return Stellar.payment(source: source, destination: destination, amount: amount, node: node)
            .then({ _ in
                let amount = Decimal(Double(amount) / 10_000_000)
                print("Sent payment of \(amount) to \(destination)")
            })
            .transformError({
                return ErrorMessage(message: "Received error while sending payment: \($0)")
            })
    }
}

func perform(_ cmds: [Command]) {
    for cmd in cmds {
        var done = false
        let continueOnError = cmd.continueOnError ?? false

        let promise: Promise<String>

        switch cmd.cmd {
        case "info":
            guard let account = cmd.account else {
                print("Missing account for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            promise = info(account: account)
        case "create":
            guard let account = cmd.account else {
                print("Missing account for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            promise = create(account: account)
        case "trust":
            guard let seed = cmd.seed else {
                print("Missing seed for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            guard let assetCode = cmd.asset_code, let assetIssuer = cmd.asset_issuer else {
                print("Missing asset for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            guard let asset = Asset(assetCode: assetCode, issuer: assetIssuer) else {
                print("Unable to create asset from: \(assetCode), \(assetIssuer)")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            let account = StellarAccount(seedStr: seed)

            promise = trust(of: asset, by: account)
        case "pay":
            guard let seed = cmd.seed else {
                print("Missing seed for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            guard let destination = cmd.destination else {
                print("Missing destination for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            guard let amount = cmd.amount else {
                print("Missing amount for \(cmd.cmd) command")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            if (cmd.asset_code != nil && cmd.asset_issuer == nil) || (cmd.asset_code == nil && cmd.asset_issuer != nil) {
                print("Incomplete asset specified: \(cmd.asset_code ?? "<nil>"), \(cmd.asset_issuer ?? "<nil>")")

                if continueOnError {
                    continue
                }

                exit(1)
            }

            var asset: Asset = .ASSET_TYPE_NATIVE
            if let code = cmd.asset_code, let issuer = cmd.asset_issuer {
                guard let a = Asset(assetCode: code, issuer: issuer) else {
                    print("Unable to creat asset from: \(cmd.asset_code ?? "") \(cmd.asset_issuer ?? "")")

                    if continueOnError {
                        continue
                    }

                    exit(1)
                }

                asset = a
            }

            let account = StellarAccount(seedStr: seed)

            promise = pay(from: account, to: destination, amount: amount, asset: asset)
        default:
            print("Unrecognized command in script: \(cmd.cmd)")
            exit(1)
        }

        promise
            .error({
                print($0)
                if !continueOnError {
                    exit(1)
                }
            })
            .finally({
                done = true
            })

        while !done {}
    }
}

var args = Array(CommandLine.arguments.dropFirst())

let path: String = {
    if args.count >= 2 && args[0] == "-c" {
        defer {
            args.remove(at: 0)
            args.remove(at: 0)
        }

        return args[1]
    }

    return "./config.json"
}()

guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    fatalError("Missing config.json")
}

do {
    let config = try JSONDecoder().decode(Configuration.self, from: data)

    xlmIssuer = StellarAccount(seedStr: config.xlm_issuer)
    node = Stellar.Node(baseURL: config.horizon_url, networkId: .custom(config.network_id))
}
catch {
    print("Unable to parse config.json: \(error)")
}

printConfig()

if args.count < 2 {
    printUsage()

    exit(0)
}

if args.count == 2 {
    switch args[0] {
    case "info":
        perform([Command(cmd: args[0],
                         continueOnError: false,
                         account: args[1],
                         seed: nil,
                         asset_code: nil,
                         asset_issuer: nil,
                         destination: nil,
                         amount: nil)])
    case "create":
        perform([Command(cmd: args[0],
                         continueOnError: false,
                         account: args[1],
                         seed: nil,
                         asset_code: nil,
                         asset_issuer: nil,
                         destination: nil,
                         amount: nil)])
    case "script":
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else {
            fatalError("Unable to load script: \(args[1])")
        }

        do {
            let cmds = try JSONDecoder().decode([Command].self, from: data)

            perform(cmds)
        }
        catch {
            fatalError("Unable to parse commands from \(args[1]): \(error)")
        }
    default:
        printUsage()
    }
}
if args.count == 4 {
    switch args[0] {
    case "trust":
        perform([Command(cmd: args[0],
                         continueOnError: false,
                         account: nil,
                         seed: args[1],
                         asset_code: args[2],
                         asset_issuer: args[3],
                         destination: nil,
                         amount: nil)])
    case "pay":
        perform([Command(cmd: args[0],
                         continueOnError: false,
                         account: nil,
                         seed: args[1],
                         asset_code: nil,
                         asset_issuer: nil,
                         destination: args[2],
                         amount: Int64(args[3]))])
    default:
        printUsage()
    }
}
else if args.count == 6 {
    switch args[0] {
    case "pay":
        perform([Command(cmd: args[0],
                         continueOnError: false,
                         account: nil,
                         seed: args[1],
                         asset_code: args[4],
                         asset_issuer: args[5],
                         destination: args[2],
                         amount: Int64(args[3]))])
    default:
        printUsage()
    }
}
