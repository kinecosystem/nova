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
    return Stellar.sequence(account: xlmIssuer.publicKey!, node: node)
        .then({ sequence -> Promise<String> in
            let ops = accounts.map({ StellarKit.Operation.createAccount(destination: $0,
                                                                        balance: 0) })
            let tx = Transaction(sourceAccount: xlmIssuer.publicKey!,
                                 seqNum: sequence,
                                 timeBounds: nil,
                                 memo: .MEMO_NONE,
                                 fee: UInt32(ops.count) * 100,
                                 operations: ops)

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
        .mapError({
            return ErrorMessage(message: "Received error establishing trust: \($0)")
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
                                 fee: UInt32(cOps.count + tOps.count) * 100,
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
    let issuer = asset == .ASSET_TYPE_NATIVE ? xlmIssuer! : StellarAccount(seedStr: issuerSeed)

    var builder = TxBuilder(source: issuer, node: node)
        .add(operations: accounts.map({ StellarKit.Operation.payment(destination: $0,
                                                                     amount: Int64(amount) * 10_000_000,
                                                                     asset: asset) }))
    if let whitelister = whitelister {
        builder = builder.add(signer: StellarAccount(seedStr: whitelister))
    }

    return builder
        .envelope(networkId: node.networkId.description)
        .then { envelope -> Promise<String> in
            return Stellar.postTransaction(envelope: envelope, node: node)
        }
        .then({ _ in
            print("Funded \(accounts.count) accounts")
        })
        .mapError({
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
                                 fee: 100,
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
        .mapError({
            return ErrorMessage(message: "Received error while setting data: \($0)")
        })
}
