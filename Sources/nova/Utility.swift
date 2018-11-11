//
//  Utility.swift
//  nova
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation

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

func read(input: String) throws -> [GeneratedPair] {
    print("Reading from: \(input)")
    let pairs = try JSONDecoder().decode(GeneratedPairWrapper.self,
                                         from: Data(contentsOf: URL(fileURLWithPath: input))).keypairs
    print("Read \(pairs.count) keys.")

    return pairs
}
