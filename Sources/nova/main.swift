//
//  main.swift
//  nova
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation
import StellarKit
import KinUtil

var node: Stellar.Node!
var whitelist: StellarAccount?
var xlmIssuer: StellarAccount!
var asset: StellarKit.Asset?
var issuerSeed: String!

enum Command: String {
    case keypairs
    case create
    case trust
    case crust
    case fund
    case whitelist
    case data
}

var path = "./config.json"
var input = "keypairs.json"
var output = "keypairs.json"
var param = ""
var skey = ""
var keyName = ""

let inputOpt = Option.string("input", shortDesc: "specify an input file [default \(input)]") { input = $0 }

let root = CmdOptNode(token: CommandLine.arguments[0],
                      subCommandRequired: true,
                      shortDesc: "perform operations on a horizon node")
    .add(options: [
        .string("config", shortDesc: "specify a configuration file [default: \(path)]") { path = $0 },
        ])
    .add(commands: [
        CmdOptNode(token: Command.keypairs.rawValue, shortDesc: "create keypairs")
            .add(options: [
                .string("output", shortDesc: "specify an output file [default \(output)]") { output = $0 },
                ]),
        CmdOptNode(token: Command.create.rawValue, shortDesc: "create accounts")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: Command.trust.rawValue, shortDesc: "trust the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: Command.crust.rawValue, shortDesc: "create accounts and trust the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: Command.fund.rawValue, shortDesc: "fund accounts with the configured asset")
            .add(options: [ inputOpt ]),
        CmdOptNode(token: Command.whitelist.rawValue, subCommandRequired: true, shortDesc: "manage the whitelist")
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
        CmdOptNode(token: Command.data.rawValue, shortDesc: "manage extra data for an account")
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
    if let error = error as? CmdOptParserErrors {
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

let command = Command(rawValue: cmdpath[0])!

switch command {
case .keypairs:
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
case .create:
    let pkeys = try read(input: input).map({ $0.address })

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        var waiting = true

        create(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]))
            .error({
                if case CreateAccountError.CREATE_ACCOUNT_ALREADY_EXIST = $0 {
                    return
                }

                print("Received error while creating account(s): \($0)")
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }
case .trust:
    guard let asset = asset else {
        print("No configured asset to trust.")
        exit(1)
    }

    let pairs = try read(input: input)

    for i in stride(from: 0, to: pairs.count, by: 10) {
        var waiting = true

        let accounts = Array(pairs[i ..< min(i + 10, pairs.count)])
            .map({ $0.seed })
            .map(StellarAccount.init(seedStr:))

        trust(accounts: accounts, asset: asset)
            .error { print($0); exit(1) }
            .finally { waiting = false }

        while waiting {}
    }
case .crust:
    guard let asset = asset else {
        print("No configured asset to trust.")
        exit(1)
    }

    let seeds = try read(input: input).map({ $0.seed })

    for i in stride(from: 0, to: seeds.count, by: 50) {
        var waiting = true

        crust(accounts: Array(seeds[i ..< min(i + 50, seeds.count)])
            .map({ StellarAccount(seedStr: $0) }), asset: asset)
            .error({
                if case CreateAccountError.CREATE_ACCOUNT_ALREADY_EXIST = $0 {
                    return
                }

                print("Received error while creating account(s): \($0)")
                exit(1)
            })
            .finally({
                waiting = false
            })

        while waiting {}
    }

    print("Created accounts and established trust")
case .fund:
    guard let asset = asset else {
        print("No configured asset to fund.")
        exit(1)
    }

    let amount = Int(remainder.first ?? "1000") ?? 10000
    let pkeys = try read(input: input).map({ $0.address })

    var waiting = true

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        waiting = true

        fund(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]), asset: asset, amount: amount)
            .error { print($0); exit(1) }
            .finally { waiting = false }

        while waiting {}
    }
case .whitelist:
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
        val = Data(account.keyPair.publicKey.suffix(4))
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
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}
case .data:
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
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}
}
