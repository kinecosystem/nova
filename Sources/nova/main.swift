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

var node: StellarKit.Node!
var whitelist: StellarAccount?
var xlmIssuer: StellarAccount!
var asset: Asset?
var issuerSeed: String!

enum Commands: String {
    case keypairs
    case create
    case fund
    case whitelist
    case data
    case pay
    case flood
}

var path = "./config.json"
var file = "keypairs.json"
var param = ""
var skey = ""
var keyName = ""
var whitelister: String?
var percentage: Int?
var amount: Int?
var priority = Int32.max

let inputOpt = Node.option("input", description: "specify an input file [default \(file)]")

let root = Node.root(CommandLine.arguments[0], "perform operations on a Horizon node", [
    .option("config", description: "specify a configuration file [default: \(path)]"),

    .command("keypairs", description: "create keypairs for use by other commands", [
        .option("output", description: "specify an output file [default \(file)]"),
        .parameter("amount", type: .int(nil)),
        ]),

    .command("create", description: "create accounts", [
        inputOpt,
        .option("key", description: "public key of the account to fund"),
        ]),

    .command("fund", description: "fund accounts, using the configured asset, if any", [
        inputOpt,
        .option("whitelist", description: "key with which to whitelist the tx"),
        .option("key", description: "public key of the account to fund"),
        .parameter("amount", type: .int(nil)),
        ]),

    .command("whitelist", description: "manage the whitelist", [
        .command("add", description: "add a key", [
            .option("priority", type: .int(1...Int(Int32.max)), description: ""),
            .parameter("key"),
            ]),

        .command("remove", description: "remove a key",
                 [.parameter("key")]),

        .command("reserve", description: "set the %capacity to reserve for non-whitelisted accounts",
                 [.parameter("percentage", type: .int(1...100))]),
        ]),

    .command("data", description: "manage data on an account", [
        .parameter("secret key", description: "secret key of account to manage"),
        .parameter("key name", description: "key of data item"),
        ]),

    .command("pay", description: "send payment to the specified account", [
        .option("whitelist", description: "key with which to whitelist the tx"),
        .parameter("secret key", description: "secret key of source account"),
        .parameter("destination key", description: "public key of destination account"),
        .parameter("amount", type: .int(nil)),
        ]),

    .command("flood", description: "Flood the network with transactions", [
        .option("amount", description: "the number of simultaneous requests; defaults to 10"),
        ])
    ])

let parseResults: ParseResults
do {
    parseResults = try parse(Array(CommandLine.arguments.dropFirst()), node: root)
}
catch let error as CmdOptParseErrors {
    switch error {
    case .unknownOption(let (str, path)):
        print("Unknown option: \(str)")
        print(usage(path))

    case .ambiguousOption(let (str, possibilities, path)):
        print("Ambiguous option: \(str)")
        print("Possible matches: " + possibilities.compactMap {
            if case let Node.parameter(opt, _) = $0 {
                return "-" + opt.token
            }

            return nil
            }.joined(separator: ", "))

        print(usage(path))

    case .missingValue(let (param, type, path)):
        print("Missing value for: \((type == .fixed ? "" : "-") + param.token)")
        print(usage(path))

    case .invalidValueType(let (param, str, type, path)):
        print("Invalid value \"\(str)\" for: \((type == .fixed ? "" : "-") + param.token)")
        print(usage(path))

    case .invalidValue(let (param, str, type, path)):
        print("Invalid value \"\(str)\" for: \((type == .fixed ? "" : "-") + param.token)")
        print(usage(path))

    case .missingSubcommand(let path):
        print(usage(path))

    default:
        break
    }

    exit(1)
}

path = parseResults["config", String.self] ?? path
file = parseResults["input", String.self] ?? file
file = parseResults["output", String.self] ?? file
param = parseResults.first(as: String.self) ?? param
skey = parseResults.first(as: String.self) ?? skey
keyName = parseResults.last(as: String.self) ?? parseResults["key", String.self] ?? keyName
whitelister = parseResults["whitelist", String.self]
percentage = parseResults.last(as: Int.self)
amount = parseResults.last(as: Int.self) ?? parseResults["amount", Int.self]
priority = Int32(parseResults["priority", Int.self] ?? Int(priority))

guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    fatalError("Missing configuration")
}

do {
    let config = try JSONDecoder().decode(Configuration.self, from: d)

    xlmIssuer = StellarAccount(seedStr: config.xlm_issuer)
    node = StellarKit.Node(baseURL: config.horizon_url, networkId: .custom(config.network_id))

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

let command = Commands(rawValue: parseResults.commandPath[1].token)!

switch command {
case .keypairs:
    let count = amount ?? 1
    var pairs = [GeneratedPair]()

    print("Generating \(count) keys.")
    for _ in 0 ..< count {
        if let seed = KeyUtils.seed(), let keypair = KeyUtils.keyPair(from: seed) {
            let pkey = StellarKit.KeyUtils.base32(publicKey: keypair.publicKey)
            let seed = StellarKit.KeyUtils.base32(seed: seed)

            pairs.append(GeneratedPair(address: pkey, seed: seed))
        }
    }

    print("Writing to: \(file)")
    try JSONEncoder().encode(GeneratedPairWrapper(keypairs: pairs))
        .write(to: URL(fileURLWithPath: file), options: [.atomic])

case .create:
    let pkeys = keyName.isEmpty
        ? try read(input: file).map({ $0.address })
        : [keyName]

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        var waiting = true

        create(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]))
            .error({
                if
                    let results = ($0 as? Responses.RequestFailure)?.transactionResult?.operationResults,
                    let inner = results[0].tr,
                    case let .CREATE_ACCOUNT(result) = inner,
                    result == .alreadyExists
                {
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

case .fund:
    let fundingAsset = asset ?? .ASSET_TYPE_NATIVE

    let amt = amount ?? 10000
    let pkeys = keyName.isEmpty
        ? try read(input: file).map({ $0.address })
        : [keyName]

    var waiting = true

    for i in stride(from: 0, to: pkeys.count, by: 100) {
        waiting = true

        fund(accounts: Array(pkeys[i ..< min(i + 100, pkeys.count)]), asset: fundingAsset, amount: amt)
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

    switch parseResults.commandPath[2].token {
    case "add":
        let account = StellarAccount(publicKey: param)
        key = account.publicKey
        val = Data(StellarKit.KeyUtils.key(base32: param).suffix(4)) //+
//            withUnsafeBytes(of: priority.bigEndian) { Data($0) }
    case "remove":
        let account = StellarAccount(publicKey: param)
        key = account.publicKey
        val = nil
    case "reserve":
        let reserve = Int32(param)
        key = "reserve"
        val = withUnsafeBytes(of: reserve!.bigEndian) { Data($0) }
    default: key = ""; val = nil
    }

    var waiting = true

    data(account: whitelist, key: key, val: val, fee: 0)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .data:
    let account = StellarAccount(seedStr: skey)
    let val = parseResults.remainder.count > 0 ? parseResults.remainder[0].data(using: .utf8) : nil

    if let val = val {
        print("Setting data [\(val.hexString)] for [\(keyName)] on account \(account.publicKey)")
    }
    else {
        print("Clearing [\(keyName)] on account \(account.publicKey)")
    }

    var waiting = true

    data(account: account, key: keyName, val: val)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .pay:
    let fundingAsset = asset ?? .ASSET_TYPE_NATIVE

    let source = StellarAccount(seedStr: skey)
    let destination = parseResults.parameterValues[1] as! String
    let amount = Int(parseResults.remainder.first ?? "1000") ?? 1000

    var waiting = true

    fund(from: source, accounts: [destination], asset: fundingAsset, amount: amount)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .flood:
    break
}
