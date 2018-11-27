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

enum Commands: String {
    case keypairs
    case create
    case fund
    case whitelist
    case data
    case pay
}

var path = "./config.json"
var input = "keypairs.json"
var output = "keypairs.json"
var param = ""
var skey = ""
var keyName = ""
var whitelister: String?
var percentage: Int?
var amount: Int?

let inputOpt = Node.option("input", description: "input file containing keypairs upon which to act")

let root = Node.root("nova", "perform operations on a horizon node", [
    .option("config", description: "specify a configuration file [default: \(path)]"),

    .command("keypairs", description: "create keypairs for use by other commands", [
        .option("output", description: "specify an output file [default \(output)]"),
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
        .command("add", description: "add a key",
                 [.parameter("key")]),

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
        print("Missing value for: \((type == .fixed ? "" : "+") + param.token)")
        print(usage(path))

    case .invalidValueType(let (param, str, type, path)):
        print("Invalid value \"\(str)\" for: \((type == .fixed ? "" : "+") + param.token)")
        print(usage(path))

    case .invalidValue(let (param, str, type, path)):
        print("Invalid value \"\(str)\" for: \((type == .fixed ? "" : "+") + param.token)")
        print(usage(path))

    case .missingSubcommand(let path):
        print(usage(path))

    default:
        break
    }

    exit(1)
}

path = parseResults.optionValues["config"] as? String ?? path
input = parseResults.optionValues["input"] as? String ?? input
output = parseResults.optionValues["output"] as? String ?? output
param = parseResults.parameterValues.first as? String ?? param
skey = parseResults.parameterValues.first as? String ?? skey
keyName = parseResults.parameterValues.last as? String ?? parseResults.optionValues["key"] as? String ?? keyName
whitelister = parseResults.optionValues["whitelist"] as? String
percentage = parseResults.parameterValues.last as? Int
amount = parseResults.parameterValues.last as? Int

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

    print("Writing to: \(output)")
    try JSONEncoder().encode(GeneratedPairWrapper(keypairs: pairs))
        .write(to: URL(fileURLWithPath: output), options: [.atomic])

case .create:
    let pkeys = keyName.isEmpty
        ? try read(input: input).map({ $0.address })
        : [keyName]

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

case .fund:
    let fundingAsset = asset ?? .ASSET_TYPE_NATIVE

    let amt = amount ?? 10000
    let pkeys = keyName.isEmpty
        ? try read(input: input).map({ $0.address })
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
        let account = StellarAccount(publickey: param)
        key = account.publicKey!
        val = Data(StellarKit.KeyUtils.key(base32: param).suffix(4))
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
    let val = parseResults.remainder.count > 0 ? parseResults.remainder[0].data(using: .utf8) : nil

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
}
