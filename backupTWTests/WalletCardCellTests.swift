//
//  WalletCardCellTests.swift
//  backupTWTests
//
//  The collapsed-stack peek mode on the card cell: a peek clips the full-height
//  card to a short header strip and refuses to self-size, a full card self-sizes
//  to its aspect ratio, and reuse returns to full.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct WalletCardCellTests {

    private func credential() -> WalletCardContent {
        .credential(CredentialCard(
            kind: "駕照電子卡", kindEnglish: "DRIVER LICENSE", issuer: "交通部公路局",
            holderName: "王〇〇", primaryMasked: "A1●●●●●●●9", trustSource: "數位發展部信任清單",
            leftField: nil, rightField: nil, tint: .green,
            backFields: [WalletCardField(label: "姓名", value: "王〇〇")]))
    }

    private func fitting(_ cell: WalletCardCell, height: CGFloat) -> CGFloat {
        let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attrs.frame = CGRect(x: 0, y: 0, width: 358, height: height)
        return cell.preferredLayoutAttributesFitting(attrs).frame.height
    }

    @Test func peekModeClipsAndTakesTheLayoutHeight() {
        let cell = WalletCardCell(frame: CGRect(x: 0, y: 0, width: 358, height: 56))
        cell.configure(credential())
        cell.setStackPeek(56)
        #expect(cell.stackPeekHeight == 56)
        #expect(cell.contentView.clipsToBounds)
        // A peek must not self-size up to the full card: it keeps the 56pt the
        // layout item gave it.
        #expect(fitting(cell, height: 56) == 56)
    }

    @Test func fullModeSelfSizesToTheCardAspect() {
        let cell = WalletCardCell(frame: CGRect(x: 0, y: 0, width: 358, height: 100))
        cell.configure(credential())
        cell.setStackPeek(nil)
        #expect(cell.stackPeekHeight == nil)
        #expect(!cell.contentView.clipsToBounds)
        // A full 1.585-aspect credential at 358 wide self-sizes to ~226pt.
        #expect(fitting(cell, height: 100) > 200)
    }

    @Test func reuseReturnsAPeekToAFullCard() {
        let cell = WalletCardCell(frame: .zero)
        cell.configure(credential())
        cell.setStackPeek(56)
        cell.prepareForReuse()
        #expect(cell.stackPeekHeight == nil)
        #expect(!cell.contentView.clipsToBounds)
    }
}
