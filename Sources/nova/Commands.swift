//
//  Commands.swift
//  nova
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation
import StellarKit
import KinUtil

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String

    var description: String {
        return message
    }
}

func create(accounts: [String]) -> Promise<String> {
    checkCreateConfig()

    return TxBuilder(source: xlmIssuer!, node: node!)
        .add(operations: accounts.map({ StellarKit.Operation.createAccount(destination: StellarKey($0)!,
                                                                           balance: 100000000000) }))
        .signedEnvelope()
        .post(to: node!)
        .then { result -> String in print("Created \(accounts.count) accounts"); return result.hash }
}

func fund(from source: StellarAccount? = nil, accounts: [String], asset: Asset, amount: Int) -> Promise<String> {
    checkFundConfig(source: source, asset: asset)

    let issuer = source ??
        (asset == .ASSET_TYPE_NATIVE ? xlmIssuer! : StellarAccount(seedStr: issuerSeed))

    let builder = TxBuilder(source: issuer, node: node!)
        .add(operations: accounts.map({ StellarKit.Operation.payment(destination: StellarKey($0)!,
                                                                     amount: Int64(amount) * 100_000,
                                                                     asset: asset) }))

    if let whitelister = cnf.whitelister {
        builder.add(signer: StellarAccount(seedStr: whitelister))
    }

    return builder
        .signedEnvelope()
        .post(to: node!)
        .then({ result -> String in
            print("Funded \(accounts.count) account(s)")
            return result.hash
        })
        .mapError({
            return ErrorMessage(message: "Received error while funding account(s): \($0)")
        })
}

func data(account: StellarAccount, key: String, val: Data?, fee: UInt32? = nil) -> Promise<String> {
    checkNodeConfig()

    return TxBuilder(source: account, node: node!)
        .add(operation: StellarKit.Operation.manageData(key: key, value: val))
        .set(fee: fee)
        .signedEnvelope()
        .post(to: node!)
        .then { result -> String in
            return result.hash
        }
        .then({ _ in
            print("Set data for \(account.publicKey)")
        })
        .mapError({
            return ErrorMessage(message: "Received error while setting data: \($0)")
        })
}

func dump() {
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
}

func list(whitelist: StellarAccount) {
    var waiting = true

    whitelist.details(node: node!)
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
}
