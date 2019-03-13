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

func parse<T: XDRDecodable>(data: Data) throws -> [T] {
    var results = [T]()

    var cursor: UInt32 = 4

    var count = try XDRDecoder(data: data[..<4]).decode(UInt32.self)
    count &= 0x7fffffff

    while true {
        let decoder = XDRDecoder(data: Data(data[cursor ..< cursor + count]))
        results.append(try T.self.init(from: decoder))

        cursor += count

        if cursor == data.count { break }

        count = try XDRDecoder(data: Data(data[cursor ..< cursor + 4])).decode(UInt32.self)
        count &= 0x7fffffff

        cursor += 4
    }

    return results
}

extension Data {
    var sha256: Data {
        return Data(bytes: SHA256([UInt8](self)).digest())
    }
}
