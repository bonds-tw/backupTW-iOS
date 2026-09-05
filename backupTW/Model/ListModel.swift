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

    /// Set when the row stands for a stored object whose text is not unique.
    ///
    /// Every row used to be identified by its words, which held for as long as
    /// the lists were fixed menus. Cards are not: two government cards of the
    /// same kind, collected in the same month, produce the same title *and* the
    /// same second line. `NSDiffableDataSourceSnapshot` treats equal items as
    /// one identifier and traps on the duplicate — so without this the second
    /// card does not draw wrongly, it terminates the app.
    let identifier: String?

    /// 「顯示但停用＋原因」（design system §8.3）：功能不可用時列仍在，
    /// `secondaryText` 說明為什麼，而不是讓按過的按鈕憑空消失。停用列
    /// 以次要色渲染且不回應點擊。
    let isEnabled: Bool

    init(image: UIImage? = nil, title: String, secondaryText: String,
         identifier: String? = nil, isEnabled: Bool = true) {
        self.image = image
        self.title = title
        self.secondaryText = secondaryText
        self.identifier = identifier
        self.isEnabled = isEnabled
    }

    // Identity is the text, never the image. `UIImage` equality is pointer
    // equality, and the home screen rebuilds its items on every appearance —
    // so with synthesized conformance every `withTintColor` call minted a
    // "different" item and the diffable data source replaced every row on
    // every visit. Rows are already matched on `title` by both screens that
    // use this type (their own comments say so); this makes the diff agree.
    //
    // The identifier joins the text rather than replacing it: identity by
    // identifier alone would make a row whose second line changed count as
    // unchanged, and the row would keep showing last week's expiry date.
    static func == (a: Item, b: Item) -> Bool {
        a.identifier == b.identifier && a.title == b.title && a.secondaryText == b.secondaryText
            && a.isEnabled == b.isEnabled
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
        hasher.combine(title)
        hasher.combine(secondaryText)
        hasher.combine(isEnabled)
    }
}
