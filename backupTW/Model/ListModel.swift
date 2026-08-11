//
//  ListModel.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/12.
//

import UIKit

struct Section: Hashable {
    let title: String
    let items: [Item]
}

struct Item: Hashable {
    let image: UIImage?
    let title: String
    let secondaryText: String

    init(image: UIImage? = nil, title: String, secondaryText: String) {
        self.image = image
        self.title = title
        self.secondaryText = secondaryText
    }

    // Identity is the text, never the image. `UIImage` equality is pointer
    // equality, and the home screen rebuilds its items on every appearance —
    // so with synthesized conformance every `withTintColor` call minted a
    // "different" item and the diffable data source replaced every row on
    // every visit. Rows are already matched on `title` by both screens that
    // use this type (their own comments say so); this makes the diff agree.
    static func == (a: Item, b: Item) -> Bool {
        a.title == b.title && a.secondaryText == b.secondaryText
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(secondaryText)
    }
}
