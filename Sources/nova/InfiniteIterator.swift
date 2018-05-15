//
//  InfiniteIterator.swift
//  stellar
//
//  Created by Kin Foundation.
//  Copyright © 2018 Kin Foundation. All rights reserved.
//

class InfiniteIterator<T>: IteratorProtocol {
    let source: AnyCollection<T>
    var iterator: AnyIterator<T>

    init(source: AnyCollection<T>) {
        self.source = source
        self.iterator = source.makeIterator()
    }

    convenience init(source: [T]) {
        self.init(source: AnyCollection(source))
    }

    func next() -> T? {
        if let v = iterator.next() {
            return v
        }

        iterator = source.makeIterator()
        return iterator.next()
    }
}
