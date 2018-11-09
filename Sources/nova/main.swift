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
    let asset: Asset?
    let whitelist: String?

    struct Asset: Decodable {
        let code: String
        let issuer: String
        let issuerSeed: String
    }
}

struct GeneratedPair: Codable {
    let address: String
    let seed: String
}

struct GeneratedPairWrapper: Codable {
    let keypairs: [GeneratedPair]
}

struct StellarAccount: Account {
    private var pubkey: String?

    var publicKey: String? {
        return pubkey ?? StellarKit.KeyUtils.base32(publicKey: keyPair.publicKey)
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

    init(publickey: String) {
        self.init(seedStr: StellarKit.KeyUtils.base32(seed: KeyUtils.seed()!))

        pubkey = publickey
    }

    init() {
        self.init(seedStr: StellarKit.KeyUtils.base32(seed: KeyUtils.seed()!))
    }

    var sign: ((Data) throws -> Data)?
}

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String

    var description: String {
        return message
    }
}

var node: Stellar.Node!
var whitelist: StellarAccount?
var xlmIssuer: StellarAccount!
var asset: StellarKit.Asset?
var issuerSeed: String!

func printConfig() {
    print(
        """
        Configuration:
        XLM Issuer: \(xlmIssuer.publicKey!)
        Node: \(node.baseURL) [\(node.networkId)]
        """
    )

    if let whitelist = whitelist {
        print("    Whitelist: \(whitelist.publicKey!)")
    }

    if let asset = asset {
        print("    Asset: [\(asset.assetCode), \(asset.issuer!)]")
    }

    print("")
}

func create(accounts: [String]) -> Promise<String> {
    return Stellar.sequence(account: xlmIssuer.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let tx = Transaction(sourceAccount: xlmIssuer.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: accounts.map({ StellarKit.Operation.createAccount(destination: $0,
                                                                                               balance: 0) }))

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: xlmIssuer,
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .then({ _ in
            print("Created \(accounts.count) accounts")
        })
}

func trust(accounts: [StellarAccount], asset: Asset) -> Promise<String> {
    var builder = TxBuilder(source: accounts[0], node: node)

    accounts.forEach {
        builder = builder.add(operation: Operation.changeTrust(asset: asset, source: $0))
        builder = builder.add(signer: $0)
    }

    return builder
        .envelope(networkId: node.networkId.description)
        .then { envelope -> Promise<String> in
            return Stellar.postTransaction(envelope: envelope, node: node)
        }
        .then({ _ in
            print("Established trust for \(accounts.count) accounts")
        })
}

func crust(accounts: [StellarAccount], asset: Asset) -> Promise<String> {
    return Stellar.sequence(account: xlmIssuer.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let cOps = accounts.map({ StellarKit.Operation.createAccount(destination: $0.publicKey!,
                                                                         balance: 0) })
            let tOps = accounts.map({ StellarKit.Operation.changeTrust(asset: asset, source: $0) })

            let tx = Transaction(sourceAccount: xlmIssuer.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: cOps + tOps)

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: xlmIssuer,
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .then({ _ in
            print("Created \(accounts.count) accounts")
        })
}

func fund(accounts: [String], asset: Asset, amount: Int) -> Promise<String> {
    return Stellar.sequence(account: asset.issuer!, node: node)
        .then({ sequence -> Promise<String> in
            let tx = Transaction(sourceAccount: asset.issuer!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: accounts.map({ StellarKit.Operation.payment(destination: $0,
                                                                                         amount: Int64(amount) * 10_000_000,
                                                                                         asset: asset) }))

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: StellarAccount(seedStr: issuerSeed),
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .then({ _ in
            print("Funded \(accounts.count) accounts")
        })
        .transformError({
            return ErrorMessage(message: "Received error while funding account(s): \($0)")
        })
}

func data(account: StellarAccount, key: String, val: Data?) -> Promise<String> {
    return Stellar.sequence(account: account.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let tx = Transaction(sourceAccount: account.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: [
                                    StellarKit.Operation.manageData(key: key, value: val)
                ])

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: account,
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .then({ _ in
            print("Set data for \(account.publicKey!)")
        })
        .transformError({
            return ErrorMessage(message: "Received error while setting data: \($0)")
        })
}

var path = "./config.json"
var input = "keypairs.json"
var output = "keypairs.json"
var param = ""
var skey = ""
var keyName = ""

let inputOpt = StringOption("input", shortDesc: "specify an input file [default \(input)]") { input = $0 }

let root = CmdOptNode(token: CommandLine.arguments[0],
                      subCommandRequired: true,
                      shortDesc: "perform operations on a horizon node")
    .add(options: [
        StringOption("config", shortDesc: "specify a configuration file [default: \(path)]") { path = $0 },
        ])
    .add(commands: [
        CmdOptNode(token: "keypairs", subCommandRequired: false, shortDesc: "create keypairs")
            .add(options: [
                StringOption("output", shortDesc: "specify an output file [default \(output)]") { output = $0 },
                ]),
        CmdOptNode(token: "create", subCommandRequired: false, shortDesc: "create accounts")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: "trust", subCommandRequired: false, shortDesc: "trust the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: "crust", subCommandRequired: false, shortDesc: "create accounts and trust the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: "fund", subCommandRequired: false, shortDesc: "fund accounts with the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: "whitelist", subCommandRequired: true, shortDesc: "manage the whitelist")
            .add(commands: [
                CmdOptNode(token: "add", shortDesc: "add a key to the whitelist")
                    .add(parameters: [
                        CmdParameter("public key") { param = $0 },
                        ]),
                CmdOptNode(token: "remove", shortDesc: "remove a key from the whitelist")
                    .add(parameters: [
                        CmdParameter("public key") { param = $0 },
                        ]),
                CmdOptNode(token: "reserve", shortDesc: "set the reserve capacity for unwhitelisted txs")
                    .add(parameters: [
                        CmdParameter("percentage") { param = $0 },
                        ]),
                ]),
        CmdOptNode(token: "data", subCommandRequired: false, shortDesc: "manage extra data for an account")
        .add(parameters: [
            CmdParameter("secret key") { skey = $0 },
            CmdParameter("key name") { keyName = $0 },
            ]),
        ])

let cmdpath: [String]
let remainder: [String]

do {
    (cmdpath, remainder) = try parse(Array(CommandLine.arguments.dropFirst()), rootNode: root)
}
catch {
    if let error = error as? Errors {
        switch error {
        case .unrecognizedOption(let opt, let node):
            print("Unrecognized option: \(opt)\n")
            print(help(node))
        case .ambiguousOption(let opt, let matches, let node):
            print("Ambiguous option \(opt) matches: \(matches.joined(separator: ", "))\n")
            print(help(node))
        case .missingOptionParameter(let opt, let node):
            print("Missing parameter for option: \(opt)\n")
            print(help(node))
        case .missingCmdParameter(let node):
            print("Missing parameter for command: \(node.token)\n")
            print(help(node))
        case .missingSubCommand(let node):
            if node !== root { print("Missing subcommand for: \(node.token)\n") }
            print(help(node))
        }
    }

    exit(1)
}

guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    fatalError("Missing configuration")
}

do {
    let config = try JSONDecoder().decode(Configuration.self, from: d)

    xlmIssuer = StellarAccount(seedStr: config.xlm_issuer)
    node = Stellar.Node(baseURL: config.horizon_url, networkId: .custom(config.network_id))

    if let a = config.asset {
        asset = StellarKit.Asset(assetCode: a.code, issuer: a.issuer)
        issuerSeed = a.issuerSeed
    }

    if let w = config.whitelist {
        whitelist = StellarAccount(seedStr: w)
    }
}
catch {
    print("Unable to parse configuration: \(error)")
}

printConfig()

if cmdpath[0] == "keypairs" {
    let count = Int(remainder.first ?? "1") ?? 1
    var pairs = [GeneratedPair]()

    print("Generating \(count) keys.")
    for _ in 0 ..< count {
        if let seed = KeyUtils.seed(), let keypair = KeyUtils.keyPair(from: seed) {
            let pkey = StellarKit.KeyUtils.base32(publicKey: keypair.publicKey)
            let seed = StellarKit.KeyUtils.base32(seed: seed)

            pairs.append(GeneratedPair(address: pkey, seed: seed))
        }
    }

    print("Writing to: \(output)")
    try JSONEncoder().encode(GeneratedPairWrapper(keypairs: pairs))
        .write(to: URL(fileURLWithPath: output), options: [.atomic])
}
else if cmdpath[0] == "create" {
    print("Reading from: \(input)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: input))).keypairs
    print("Read \(pairs.count) keys.")

    let pkeys = pairs.map({ $0.address })

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        var waiting = true

        create(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]))
            .error({
                if case CreateAccountError.CREATE_ACCOUNT_ALREADY_EXIST = $0 {
                    return
                }

                print(ErrorMessage(message: "Received error while creating account(s): \($0)"))
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }
}
else if cmdpath[0] == "trust" {
    guard let asset = asset else {
        print("No configured asset to trust.")
        exit(1)
    }

    print("Reading from: \(input)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: input))).keypairs
    print("Read \(pairs.count) keys.")

    for i in stride(from: 0, to: pairs.count, by: 10) {
        var waiting = true

        trust(accounts: Array(pairs[i ..< min(i + 10, pairs.count)]).map({ $0.seed }).map(StellarAccount.init(seedStr:)), asset: asset)
            .error({
                print(ErrorMessage(message: "Received error while establishing trust: \($0)"))
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }
}
else if cmdpath[0] == "crust" {
    guard let asset = asset else {
        print("No configured asset to trust.")
        exit(1)
    }

    print("Reading from: \(input)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: input))).keypairs
    print("Read \(pairs.count) keys.")

    let seeds = pairs.map({ $0.seed })

    for i in stride(from: 0, to: seeds.count, by: 50) {
        var waiting = true

        crust(accounts: Array(seeds[i ..< min(i + 50, seeds.count)]).map({ StellarAccount(seedStr: $0) }), asset: asset)
            .error({
                if case CreateAccountError.CREATE_ACCOUNT_ALREADY_EXIST = $0 {
                    return
                }

                print(ErrorMessage(message: "Received error while creating account(s): \($0)"))
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }

    print("Created accounts and established trust")
}
else if cmdpath[0] == "fund" {
    guard let asset = asset else {
        print("No configured asset to fund.")
        exit(1)
    }

    let amount = Int(remainder.first ?? "1000") ?? 10000

    print("Reading from: \(input)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: input))).keypairs
    print("Read \(pairs.count) keys.")

    var waiting = true
    let pkeys = pairs.map({ $0.address })

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        waiting = true

        fund(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]), asset: asset, amount: amount)
            .error({
                print($0)
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }
}
else if cmdpath[0] == "whitelist" {
    guard let whitelist = whitelist else {
        print("Whitelist seed not configured.")
        exit(1)
    }

    let key: String
    let val: Data?

    switch cmdpath[1] {
    case "add":
        let account = StellarAccount(publickey: param)
        key = account.publicKey!
        val = account.keyPair.publicKey.suffix(4)
    case "remove":
        let account = StellarAccount(publickey: param)
        key = account.publicKey!
        val = nil
    case "reserve":
        let reserve = Int32(param)
        key = "reserve"
        val = withUnsafeBytes(of: reserve!.bigEndian) { Data($0) }
    default: key = ""; val = nil
    }

    var waiting = true

    data(account: whitelist, key: key, val: val)
        .error({
            print($0)
            exit(1)
        })
        .finally({
            waiting = false
        })

    while waiting {}
}
else if cmdpath[0] == "data" {
    let account = StellarAccount(seedStr: skey)
    let val = remainder.count > 0 ? remainder[0].data(using: .utf8) : nil

    if let val = val {
        print("Setting data [\(val.hexString)] for [\(keyName)] on account \(account.publicKey!)")
    }
    else {
        print("Clearing [\(keyName)] on account \(account.publicKey!)")
    }

    var waiting = true

    data(account: account, key: keyName, val: val)
        .error({
            print($0)
            exit(1)
        })
        .finally({
            waiting = false
        })

    while waiting {}
}
