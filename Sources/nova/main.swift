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
import Gzip

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
    case dump
    case seed
}

enum WhitelistCommands: String {
    case list
    case add
    case remove
    case priority
    case reserve
}

let path = "./config.json"
let file = "keypairs.json"

class Config {
    var path = "./config.json"
    var file = "keypairs.json"
    var passphrase: String!
    var whitelistOverride: String?
    var funderOverride: String?
    var amount: Int!
    var skey: String!
    var whitelister: String?
    var percentages: [Int]?
    var percentage: Int!
    var priority = Int32.max
    var keyName = ""
    var value: Data?
}

let cnf = Config()

let root = Command(description: "perform operations on a Horizon node", bindTarget: cnf)
    .option("config", binding: \Config.path, description: "specify a configuration file [default: \(cnf.path)]")
    .option("cfg-funder",
            binding: \Config.funderOverride,
            description: "override the funder secret key from the configuration file")
    .option("cfg-whitelist",
            binding: \Config.whitelistOverride,
            description: "override the whitelist secret key from the configuration file")

    .command(Commands.keypairs, description: "create keypairs for use by other commands") {
        $0
            .option("output", binding: \Config.file, description: "specify an output file [default \(cnf.file)]")
            .parameter("amount", type: .int(nil), binding: \Config.amount)
    }
    .command(Commands.create, description: "create accounts") {
        $0
            .option("input", binding: \Config.file, description: "specify an input file [default \(cnf.file)]")
            .option("key", binding: \Config.keyName, description: "public key of the account to fund")
    }
    .command(Commands.fund, description: "fund accounts, using the configured asset, if any") {
        $0
            .option("input", binding: \Config.file, description: "specify an input file [default \(cnf.file)]")
            .option("whitelist", binding: \Config.whitelister, description: "key with which to whitelist the tx")
            .option("key", binding: \Config.keyName, description: "public key of the account to fund")
            .parameter("amount", type: .int(nil), binding: \Config.amount)
    }
    .command(Commands.whitelist, description: "manage the whitelist") {
        $0.command(WhitelistCommands.list, description: "list the whitelist contents and configuration")

        $0.command(WhitelistCommands.add, description: "add a key") {
            $0
                .option("priority", type: .int(1...Int(Int32.max)), binding: \Config.priority)
                .parameter("key", binding: \Config.keyName)
        }

        $0.command(WhitelistCommands.remove, description: "remove a key") {
            $0.parameter("key", binding: \Config.keyName)
        }

        $0.command(WhitelistCommands.reserve, description: "set the %capacity to reserve for non-whitelisted accounts") {
            $0.parameter("percentage", type: .int(1...100), binding: \Config.percentage)
        }

        $0.command(WhitelistCommands.priority, description: "set the percentages to allocate across priorities") {
            $0
                .parameter("level", type: .int(1...20), binding: \Config.priority)
                .parameter("percentages", type: .array(.int(1...100)), binding: \Config.percentages)
        }
    }
    .command(Commands.data, description: "manage data on an account") {
        $0.parameter("secret key", binding: \Config.skey, description: "secret key of account to manage")
        $0.parameter("key name", binding: \Config.keyName, description: "key of data item")
        $0.optional("value",
                    type: .custom({ $0.data(using: .utf8) }),
                    binding: \Config.value,
                    description: "the value to set; blank to delete <key name>")
    }
    .command(Commands.pay, description: "send payment to the specified account") {
        $0
            .option("whitelist", binding: \Config.whitelister, description: "key with which to whitelist the tx")
            .parameter("secret key", binding: \Config.skey, description: "secret key of source account")
            .parameter("destination key", binding: \Config.keyName, description: "public key of destination account")
            .parameter("amount", type: .int(nil), binding: \Config.amount)
    }
    .command(Commands.dump, description: "dump an xdr file from a history archive as JSON") {
        $0.parameter("file", binding: \Config.file, description: "the file to dump.  May be gzipped")
    }
    .command(Commands.seed, description: "generate network seed from passphrase") {
        $0.parameter("passphrase", binding: \Config.passphrase)
}

let parseResults: ParseResults
do {
    parseResults = try parse(CommandLine.arguments.dropFirst(), node: root)
}
catch let error as CmdOptParseErrors {
    switch error {
    case .unknownOption(let (str, path)):
        print("Unknown option: \(str)")
        print(usage(path))

    case .ambiguousOption(let (str, possibilities, path)):
        print("Ambiguous option: \(str)")
        print("Possible matches: " + possibilities.map { "-" + $0.token}
            .joined(separator: ", "))

        print(usage(path))

    case .missingValue(let (param, path)):
        print("Missing value for: \((param is Option ? "-" : "") + param.token)")
        print(usage(path))

    case .invalidValueType(let (param, str, path)):
        print("Invalid value \"\(str)\" for: \((param is Option ? "-" : "") + param.token)")
        print(usage(path))

    case .invalidValue(let (param, str, path)):
        print("Invalid value \"\(str)\" for: \((param is Option ? "-" : "") + param.token)")
        print(usage(path))

    case .missingSubcommand(let path):
        print(usage(path))

    default:
        break
    }

    exit(1)
}

if let d = try? Data(contentsOf: URL(fileURLWithPath: cnf.path)) {
    do {
        let config = try JSONDecoder().decode(Configuration.self, from: d)

        if let f = (cnf.funderOverride ?? config.funder) {
            xlmIssuer = StellarAccount(seedStr: f)
        }

        node = StellarKit.Node(baseURL: config.horizon_url, networkId: NetworkId(config.network_id))

        if let a = config.asset {
            asset = StellarKit.Asset(assetCode: a.code, issuer: StellarKey(a.issuer)!)
            issuerSeed = a.issuerSeed
        }

        if let w = (cnf.whitelistOverride ?? config.whitelist) {
            whitelist = StellarAccount(seedStr: w)
        }
    }
    catch {
        print("Unable to parse configuration: \(error)")
    }
}

func read(_ byteCount: Int, from data: Data, into: UnsafeMutableRawPointer) {
    data.withUnsafeBytes({ (ptr: UnsafePointer<UInt8>) -> () in
        memcpy(into, ptr, byteCount)
    })
}

let command = parseResults.commands[0] as! Commands

if command != .dump && command != .seed {
    printConfig()
}

switch command {
case .keypairs:
    let count = cnf.amount ?? 1
    var pairs = [GeneratedPair]()

    print("Generating \(count) keys.")
    for _ in 0 ..< count {
        if let seed = KeyUtils.seed(), let keypair = KeyUtils.keyPair(from: seed) {
            let pkey = StellarKey(keypair.publicKey, type: .ed25519PublicKey)
            let seed = StellarKey(seed, type: .ed25519SecretSeed)

            pairs.append(GeneratedPair(address: pkey.description, seed: seed.description))
        }
    }

    print("Writing to: \(cnf.file)")
    try JSONEncoder().encode(GeneratedPairWrapper(keypairs: pairs))
        .write(to: URL(fileURLWithPath: cnf.file), options: [.atomic])

case .create:
    let pkeys = cnf.keyName.isEmpty
        ? try read(input: cnf.file).map({ $0.address })
        : [cnf.keyName]

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

    let amt = cnf.amount ?? 10000
    let pkeys = cnf.keyName.isEmpty
        ? try read(input: cnf.file).map({ $0.address })
        : [cnf.keyName]

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

    switch parseResults.commands[1] as! WhitelistCommands {
    case .list:
        var waiting = true

        whitelist.details(node: node)
            .then({ details in
                let overrides = details.data.filter { $0.0.starts(with: "priority_count_") }
                let keys = details.data.filter { $0.0.utf8.count == 56 }

                if let reserve = details.data.filter({ $0.0 == "reserve" }).first {
                    var r = Int32()
                    read(4, from: Data(base64Encoded: reserve.1)!, into: &r)

                    print("Reserve: \(r.bigEndian)\n")
                }

                print("Priority overrides")
                print("------------------")
                for p in overrides.keys.sorted() {
                    let v = overrides[p]!
                    print("  \(p.suffix(2)): \(Array(Data(base64Encoded: v)!))")
                }

                print("\nKeys                                                        Priority")
                print("--------------------------------------------------------------------")
                for k in keys {
                    var p = ""

                    let d = Data(base64Encoded: k.1)!
                    if d.count == 8 {
                        let pd = d.suffix(4)
                        var pi = Int32()
                        read(4, from: pd, into: &pi)

                        p = String(describing: pi.bigEndian)
                    }

                    print("\(k.0)\t\(p)")
                }
            })
            .error { print($0) }
            .finally { waiting = false }

        while waiting {}

        exit(0)

    case .add:
        let stellarKey = StellarKey(cnf.keyName)!
        key = String(stellarKey)
        val = Data(stellarKey.key.suffix(4))
    case .remove:
        let stellarKey = StellarKey(cnf.keyName)!
        key = String(stellarKey)
        val = nil
    case .reserve:
        let reserve = Int32(cnf.percentage)
        key = "reserve"
        val = withUnsafeBytes(of: reserve.bigEndian) { Data($0) }
    case .priority:
        guard
            let percentages = cnf.percentages,
            percentages.count == cnf.priority
        else {
            print("Mismatch between priority level and number of percentages.")
            exit(1)
        }

        key = String(format: "priority_count_%02d", cnf.priority)
        val = Data(bytes: percentages.map({ UInt8(clamping: $0) }))
    }

    var waiting = true

    data(account: whitelist, key: key, val: val, fee: 100)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .data:
    let account = StellarAccount(seedStr: cnf.skey)
    let val = cnf.value

    if let val = val {
        print("Setting data [\(val.hexString)] for [\(cnf.keyName)] on account \(account.publicKey)")
    }
    else {
        print("Clearing [\(cnf.keyName)] on account \(account.publicKey)")
    }

    var waiting = true

    data(account: account, key: cnf.keyName, val: val)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .pay:
    let fundingAsset = asset ?? .ASSET_TYPE_NATIVE

    let source = StellarAccount(seedStr: cnf.skey)
    let destination = cnf.keyName
    let amount = cnf.amount ?? 1000

    var waiting = true

    fund(from: source, accounts: [destination], asset: fundingAsset, amount: amount)
        .error { print($0); exit(1) }
        .finally { waiting = false }

    while waiting {}

case .dump:
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: cnf.file))
        let uncompressed = cnf.file.hasSuffix(".gz")
            ? try data.gunzipped()
            : data

        let jsonEnc = JSONEncoder()
        jsonEnc.outputFormatting = .prettyPrinted

        let filename = cnf.file.split(separator: "/").last!
        if filename.starts(with: "ledger-") {
            let results: [LedgerHeaderHistoryEntry] = try parse(data: uncompressed)

            let json = try jsonEnc.encode(results)
            print(String(bytes: json, encoding: .utf8)!)
        }
        else if filename.starts(with: "transactions-") {
            let results: [TransactionHistoryEntry] = try parse(data: uncompressed)

            let json = try jsonEnc.encode(results)
            print(String(bytes: json, encoding: .utf8)!)
        }
        else if filename.starts(with: "results-") {
            let results: [TransactionHistoryResultEntry] = try parse(data: uncompressed)

            let json = try jsonEnc.encode(results)
            print(String(bytes: json, encoding: .utf8)!)
        }
        else if filename.starts(with: "bucket-") {
            let results: [BucketEntry] = try parse(data: uncompressed)

            let json = try jsonEnc.encode(results)
            print(String(bytes: json, encoding: .utf8)!)
        }
        else {
            print("Unknown archive type.")
        }
    }
    catch {
        print(error)
    }

case .seed:
    let sha = cnf.passphrase.data(using: .utf8)!.sha256
    print("Seed: \(StellarKey(sha, type: .ed25519SecretSeed))")
}
