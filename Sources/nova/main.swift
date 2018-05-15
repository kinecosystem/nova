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

func printConfig() {
    print(
        """
        Configuration:
            XLM Issuer: \(xlmIssuer.publicKey!)
            Node: \(node.baseURL) [\(node.networkId)]
        """
    )

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
        .transformError({
            return ErrorMessage(message: "Received error while creating account(s): \($0)")
        })
}

func trust(account: StellarAccount, asset: Asset) -> Promise<String> {
    return Stellar.sequence(account: account.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let tx = Transaction(sourceAccount: account.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 operations: [ StellarKit.Operation.changeTrust(asset: asset) ])

            let envelope = try Stellar.sign(transaction: tx,
                                            signer: account,
                                            node: node)

            return Stellar.postTransaction(envelope: envelope, node: node)
        })
        .transformError({
            return ErrorMessage(message: "Received error while establishing trust: \($0)")
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

func exhaust(source: StellarAccount, destinations: [String], asset: Asset) -> Promise<String> {
    let p = Promise<String>()
    let destinationIterator = InfiniteIterator(source: destinations)

    let queue = DispatchQueue(label: "", attributes: .concurrent)

    Stellar.sequence(account: source.publicKey!, node: node)
        .then({
            var seqNum = $0

            queue.async {
                if let result = p.result, case .error = result {
                    return
                }

                queue.async {
                    guard let destination = destinationIterator.next() else {
                        p.signal(ErrorMessage(message: "Ran out of destinations?!"))

                        return
                    }

                    seqNum += _exhaust(source: source,
                                       destination: destination,
                                       seqNum: seqNum,
                                       asset: asset,
                                       p: p)
                }
            }
        })

    return p
}

func _exhaust(source: StellarAccount, destination: String, seqNum: UInt64, asset: Asset, p: Promise<String>) -> UInt64 {
    var waiting = true

    let tx = Transaction(sourceAccount: source.publicKey!,
                         seqNum: seqNum,
                         timeBounds: nil,
                         memo: .MEMO_NONE,
                         operations: [ StellarKit.Operation.payment(destination: destination,
                                                                    amount: Int64(1 * 10_000_000),
                                                                    asset: asset) ])

    do {
        let envelope = try Stellar.sign(transaction: tx,
                                        signer: source,
                                        node: node)

        print("--- posting transaction")
        Stellar.postTransaction(envelope: envelope, node: node)
            .then({ _ in
                print("--- transaction posted")
            })
            .error({
                print("--- transaction failed")

                if case PaymentError.PAYMENT_UNDERFUNDED = $0 {
                    p.signal($0)
                }
                else {
                    print($0)
                }
            })
            .finally({
                waiting = false
            })
    }
    catch {
        waiting = false
    }

    while waiting {}

    if let result = p.result, case .error = result {
        return seqNum
    }

    return seqNum + 1
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
    fatalError("Missing configuration")
}

do {
    let config = try JSONDecoder().decode(Configuration.self, from: data)

    xlmIssuer = StellarAccount(seedStr: config.xlm_issuer)
    node = Stellar.Node(baseURL: config.horizon_url, networkId: .custom(config.network_id))

    if let a = config.asset {
        asset = StellarKit.Asset(assetCode: a.code, issuer: a.issuer)
        issuerSeed = a.issuerSeed
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
                print($0)
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

    var inProgress = pairs.count
    let seeds = pairs.map({ $0.seed })

    for seed in seeds {
        trust(account: StellarAccount(seedStr: seed), asset: asset)
            .error({
                print($0)
                exit(1)
            })
            .finally({
                inProgress -= 1
            })
    }

    while inProgress > 0 {}

    print("Established trust")
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
else if cmd == "flood" {
    guard let asset = asset else {
        print("No configured asset to flood.")
        exit(1)
    }

    var path = "keypairs.json"
    if let index = args.index(of: "-i"), index != args.endIndex {
        path = args[args.index(after: index)]
    }

    var destPath = "destinations.json"
    if let index = args.index(of: "-d"), index != args.endIndex {
        destPath = args[args.index(after: index)]
    }

    print("Reading sources from: \(path)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: path))).keypairs
    print("Read \(pairs.count) keys.")

    print("Reading destinations from: \(destPath)")
    let destinations = try JSONDecoder().decode([GeneratedPair].self,
                                                from: Data(contentsOf: URL(fileURLWithPath: destPath)))
    print("Read \(destinations.count) keys.")

    var inProgress = pairs.count
    let seeds = pairs.map({ $0.seed })

    print("Starting flood.")

    for seed in seeds {
        exhaust(source: StellarAccount(seedStr: seed), destinations: destinations.map({ $0.address }), asset: asset)
            .error({
                print($0)

                if case PaymentError.PAYMENT_UNDERFUNDED = $0 {

                }
                else {
                    exit(1)
                }
            })
            .finally({
                inProgress -= 1
            })
    }

    while inProgress > 0 {}
}
