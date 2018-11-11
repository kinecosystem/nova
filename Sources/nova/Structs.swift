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
    private var pubkey: String?

    var publicKey: String? {
        return pubkey ?? StellarKit.KeyUtils.base32(publicKey: keyPair.publicKey)
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

    init(publickey: String) {
        self.init(seedStr: StellarKit.KeyUtils.base32(seed: KeyUtils.seed()!))

        pubkey = publickey
    }

    init() {
        self.init(seedStr: StellarKit.KeyUtils.base32(seed: KeyUtils.seed()!))
    }

    var sign: ((Data) throws -> [UInt8])?
}

