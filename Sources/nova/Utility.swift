//
//  Utility.swift
//  nova
//
//  Created by Kin Ecosystem.
//  Copyright © 2018 Kin Ecosystem. All rights reserved.
//

import Foundation
import StellarKit

func printConfig() {
    print(
        """
        Configuration:
        XLM Issuer: \(xlmIssuer.publicKey)
        Node: \(node.baseURL) [\(node.networkId)]
        """
    )

    if let whitelist = whitelist {
        print("    Whitelist: \(whitelist.publicKey)")
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

func chunkArchiveData(_ data: Data, closure: (Data) throws -> ()) throws {
    var cursor: UInt32 = 4

    var count = try XDRDecoder(data: data[..<4]).decode(UInt32.self)
    count &= 0x7fffffff

    while true {
        try closure(data[cursor ..< cursor + count])

        cursor += count

        if cursor == data.count { break }

        count = try XDRDecoder(data: data[cursor ..< cursor + 4])
            .decode(UInt32.self)
        count &= 0x7fffffff

        cursor += 4
    }
}

func parse<T: XDRDecodable>(data: Data) throws -> [T] {
    var results = [T]()

    try chunkArchiveData(data) {
        let decoder = XDRDecoder(data: $0)
        results.append(try T.self.init(from: decoder))
    }

    return results
}
