//
//  Structs.swift
//  nova
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation
import StellarKit
import Sodium

struct Configuration: Decodable {
    let funder: String?
    let horizon_url: URL?
    let network_id: String?
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
    let keyPair: Sign.KeyPair
    let publicKey: StellarKey

    func sign<S>(_ message: S) throws -> [UInt8] where S : Sequence, S.Element == UInt8 {
        return try KeyUtils.sign(message: Data(message), signingKey: keyPair.secretKey)
    }

    init(stellarKey: StellarKey) {
        if stellarKey.type == .ed25519PublicKey {
            publicKey = stellarKey
            keyPair = KeyUtils.keyPair(from: KeyUtils.seed()!)!
        }
        else {
            keyPair = KeyUtils.keyPair(from: String(stellarKey))!
            publicKey = StellarKey(keyPair.publicKey)
        }
    }

    init(seedStr: String) {
        keyPair = KeyUtils.keyPair(from: seedStr)!
        publicKey = StellarKey(keyPair.publicKey)
    }

    init(publicKey: String) {
        self.publicKey = StellarKey(publicKey)!
        keyPair = KeyUtils.keyPair(from: KeyUtils.seed()!)!
    }

    init() {
        keyPair = KeyUtils.keyPair(from: KeyUtils.seed()!)!
        publicKey = StellarKey(keyPair.publicKey)
    }
}

