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
var asset: StellarKit.Asset?
var issuerSeed: String!
var whitelist: StellarAccount?

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
                                                                                               balance: 100 * 10000000) }))

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
                                                                         balance: 100 * 10000000) })
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

if args.isEmpty {
    exit(0)
}

let cmd = args[0]
args.remove(at: 0)

if cmd == "keypairs" {
    let count = Int(args.first ?? "1") ?? 1
    var pairs = [GeneratedPair]()

    var path = "keypairs.json"
    if let index = args.index(of: "-o"), index != args.endIndex {
        path = args[args.index(after: index)]
    }

    print("Generating \(count) keys.")
    for _ in 0 ..< count {
        if let seed = KeyUtils.seed(), let keypair = KeyUtils.keyPair(from: seed) {
            let pkey = StellarKit.KeyUtils.base32(publicKey: keypair.publicKey)
            let seed = StellarKit.KeyUtils.base32(seed: seed)

            pairs.append(GeneratedPair(address: pkey, seed: seed))
        }
    }

    print("Writing to: \(path)")
    try JSONEncoder().encode(GeneratedPairWrapper(keypairs: pairs)).write(to: URL(fileURLWithPath: path), options: [.atomic])
}
else if cmd == "create" {
    var path = "keypairs.json"
    if let index = args.index(of: "-i"), index != args.endIndex {
        path = args[args.index(after: index)]
    }

    print("Reading from: \(path)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: path))).keypairs
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
else if cmd == "trust" {
    guard let asset = asset else {
        print("No configured asset to trust.")
        exit(1)
    }

    var path = "keypairs.json"
    if let index = args.index(of: "-i"), index != args.endIndex {
        path = args[args.index(after: index)]
    }

    print("Reading from: \(path)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: path))).keypairs
    print("Read \(pairs.count) keys.")

    for i in stride(from: 0, to: pairs.count, by: 10) {
        var waiting = true

        trust(accounts: Array(pairs[i ..< min(i + 10, pairs.count)]).map({ $0.seed }).map(StellarAccount.init), asset: asset)
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
else if cmd == "crust" {
  guard let asset = asset else {
      print("No configured asset to trust.")
      exit(1)
  }

  var path = "keypairs.json"
  if let index = args.index(of: "-i"), index != args.endIndex {
      path = args[args.index(after: index)]
  }

  print("Reading from: \(path)")
  let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                       from: Data(contentsOf: URL(fileURLWithPath: path))).keypairs
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
else if cmd == "fund" {
    guard let asset = asset else {
        print("No configured asset to fund.")
        exit(1)
    }

    let amount = Int(args.first ?? "1000") ?? 10000

    var path = "keypairs.json"
    if let index = args.index(of: "-i"), index != args.endIndex {
        path = args[args.index(after: index)]
    }

    print("Reading from: \(path)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: path))).keypairs
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
else if cmd == "data" {
    guard (2...3).contains(args.count) else {
        print("Invalid parameters.  Expected: <secret key> <key> [<value>]")
        exit(1)
    }

    let account = StellarAccount(seedStr: args[0])
    let key = args[1]
    let val = args.count == 3 ? args[2].data(using: .utf8) : nil

    print("Setting data [\(String(describing: val))] for [\(key)] on account \(account.publicKey!)")

    var waiting = true

    data(account: account, key: key, val: val)
        .error({
            print($0)
            exit(1)
        })
        .finally({
            waiting = false
        })

    while waiting {}
}
else if cmd == "whitelist" {
    guard let whitelist = whitelist else {
        print("Whitelist seed not configured.")
        exit(1)
    }

    guard args.count == 2 else {
        print("Invalid parameters.  Expected: [add | remove] <key>")
        exit(1)
    }

    let cmd = args[0]

    guard cmd == "add" || cmd == "remove" else {
        print("Invalid command: \(cmd)")
        exit(1)
    }

    let account = StellarAccount(seedStr: args[1])

    let val: Data?
    if cmd == "add" {
        val = account.keyPair.publicKey.suffix(4)
        print("Adding \(account.publicKey!) to whitelist.")
    }
    else {
        val = nil
        print("Removing \(account.publicKey!) from whitelist.")
    }

    var waiting = true

    data(account: whitelist, key: account.publicKey!, val: val)
        .error({
            print($0)
            exit(1)
        })
        .finally({
            waiting = false
        })

    while waiting {}
}
