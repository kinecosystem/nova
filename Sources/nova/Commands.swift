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
    return TxBuilder(source: xlmIssuer, node: node)
        .add(operations: accounts.map({ StellarKit.Operation.createAccount(destination: StellarKey($0)!,
                                                                           balance: 1000000000) }))
        .signedEnvelope()
        .post(to: node)
        .then { result -> String in print("Created \(accounts.count) accounts"); return result.hash }
}

func fund(from source: StellarAccount? = nil, accounts: [String], asset: Asset, amount: Int) -> Promise<String> {
    let issuer = source ??
        (asset == .ASSET_TYPE_NATIVE ? xlmIssuer! : StellarAccount(seedStr: issuerSeed))

    let builder = TxBuilder(source: issuer, node: node)
        .add(operations: accounts.map({ StellarKit.Operation.payment(destination: StellarKey($0)!,
                                                                     amount: Int64(amount) * 100_000,
                                                                     asset: asset) }))

    if let whitelister = whitelister {
        builder.add(signer: StellarAccount(seedStr: whitelister))
    }

    return builder
        .signedEnvelope()
        .post(to: node)
        .then({ result -> String in
            print("Funded \(accounts.count) account(s)")
            return result.hash
        })
        .mapError({
            return ErrorMessage(message: "Received error while funding account(s): \($0)")
        })
}

func data(account: StellarAccount, key: String, val: Data?, fee: UInt32? = nil) -> Promise<String> {
    return TxBuilder(source: account, node: node)
        .add(operation: StellarKit.Operation.manageData(key: key, value: val))
        .set(fee: fee)
        .signedEnvelope()
        .post(to: node)
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

func flood(_ opsPerTx: Int) {
    let requestor = Horizon()
    
    while true {
        _ =
            TxBuilder(source: xlmIssuer, node: node)
                .set(fee: UInt32(100 * opsPerTx))
                .add(operations: (0 ..< opsPerTx).compactMap { _ in
                    if let seed = KeyUtils.seed(), let keypair = KeyUtils.keyPair(from: seed) {
                        return StellarKit.Operation
                            .createAccount(destination: StellarKey(keypair.publicKey),
                                           balance: 123)
                    }

                    return nil
                })
                .signedEnvelope()
                .post(to: node, using: requestor)
    }
}
