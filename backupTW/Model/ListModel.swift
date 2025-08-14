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
}
