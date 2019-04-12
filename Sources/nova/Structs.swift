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
    let stellarKey: StellarKey
    let keyPair: Sign.KeyPair

    var publicKey: String {
        if stellarKey.type == .ed25519PublicKey {
            return stellarKey.description
        }
        
        return StellarKey(keyPair.publicKey).description
    }

    func sign<S>(_ message: S) throws -> [UInt8] where S : Sequence, S.Element == UInt8 {
        return try KeyUtils.sign(message: Data(message), signingKey: keyPair.secretKey)
    }

    init(stellarKey: StellarKey) {
        self.stellarKey = stellarKey

        if stellarKey.type == .ed25519SecretSeed {
            keyPair = KeyUtils.keyPair(from: stellarKey.description)!
        }
        else {
            keyPair = KeyUtils.keyPair(from: KeyUtils.seed()!)!
        }
    }

    init(seedStr: String) {
        stellarKey = StellarKey(seedStr)!
        keyPair = KeyUtils.keyPair(from: seedStr)!
    }

    init(publicKey: String) {
        stellarKey = StellarKey(publicKey)!
        keyPair = KeyUtils.keyPair(from: KeyUtils.seed()!)!
    }

    init() {
        stellarKey = StellarKey(KeyUtils.seed()!, type: .ed25519SecretSeed)
        keyPair = KeyUtils.keyPair(from: stellarKey.key)!
    }
}

