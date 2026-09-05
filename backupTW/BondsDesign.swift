//
//  BondsDesign.swift
//  backupTW
//
//  「有備而來」（Bonds）設計系統的 token 層——全 app 唯一的來源。
//  規範全文見 docs/design-system.md。個別畫面不再出現字面 duration、
//  圓角、間距或強調色；新增顏色前先問：這是哪個語意 token？
//
//  主色決策：互動色是靛（AccentColor.colorset：light #4B4ED6 / dark
//  #7D7AFF），不是綠——綠、橙、紅已被查驗判定語意佔用（安全關鍵），
//  互動色必須與它們全部拉開。墨松綠（#0D5B48）是品牌識別色，只用於
//  卡面與品牌面，不做互動元件，不隨深淺色變。
//

import UIKit

enum Bonds {

    // MARK: - 色彩

    enum Color {
        /// 全域互動色。真正的定義在 AccentColor.colorset；這裡透過
        /// `.tintColor` 取得，跟隨 trait 動態解析。
        static let accent = UIColor.tintColor

        /// 品牌識別色（墨松綠）。只用於卡面與品牌面。
        static let brandInk = UIColor(red: 0x0D / 255, green: 0x5B / 255, blue: 0x48 / 255, alpha: 1)

        /// 判定三色。呈現規格固定為「0.14 alpha 色底＋SF Symbol tint＋
        /// `.label` 文字」——裸色文字實測過 1.99:1，禁用。
        enum Verdict {
            static let pass = UIColor.systemGreen
            static let caution = UIColor.systemOrange
            static let fail = UIColor.systemRed
            static func fill(_ base: UIColor) -> UIColor { base.withAlphaComponent(0.14) }
        }
    }

    // MARK: - 字體排印

    /// 六個角色，全部 Dynamic Type。固定 pt 只允許出現在卡面
    /// （`WalletCardView`，模擬實體證件的封閉規格）。
    enum Font {
        /// 頁內大標。收斂舊有的 title2／title3／largeTitle／34pt／22pt
        /// 五種做法。
        static var pageTitle: UIFont {
            let base = UIFont.preferredFont(forTextStyle: .title2)
            guard let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
            return UIFont(descriptor: bold, size: 0)
        }
        /// 品牌大標——首頁／使用分頁頂端那一行，視覺上等同 large title。
        static var brandTitle: UIFont {
            let base = UIFont.preferredFont(forTextStyle: .largeTitle)
            guard let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
            return UIFont(descriptor: bold, size: 0)
        }
        static var sectionTitle: UIFont { .preferredFont(forTextStyle: .headline) }
        static var body: UIFont { .preferredFont(forTextStyle: .body) }
        static var secondary: UIFont { .preferredFont(forTextStyle: .subheadline) }
        static var caption: UIFont { .preferredFont(forTextStyle: .footnote) }
        /// 識別碼、指紋、DID 用的等寬字，包 `UIFontMetrics` 跟隨 Dynamic Type。
        static func mono(_ style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular) -> UIFont {
            let size = UIFont.preferredFont(forTextStyle: style).pointSize
            return UIFontMetrics(forTextStyle: style)
                .scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight))
        }
    }

    // MARK: - 間距

    /// 4pt 網格。頁面左右邊距 20、卡片容器內距 16、卡面內距 20。
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let page: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 形狀

    /// 一律搭配 `layer.cornerCurve = .continuous`；`round(_:_:)` 幫你記住。
    enum Radius {
        /// 頁面級卡片容器。
        static let container: CGFloat = 16
        /// 巢狀卡、caveat 卡。
        static let card: CGFloat = 12
        /// 皮夾卡面。
        static let walletCard: CGFloat = 20
    }

    static func round(_ layer: CALayer, _ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    // MARK: - 高度

    enum Shadow {
        /// 全 app 唯一的一套陰影。深色模式下自然弱化，不另調。
        static func card(_ layer: CALayer) {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 22
            layer.shadowOffset = CGSize(width: 0, height: 12)
        }
    }

    // MARK: - 動態

    /// Reduce Motion 的三條既有規則照舊：翻面直接換面、QR 輪播幀間隔
    /// 加倍、傾斜特效不啟動。
    enum Motion {
        /// 狀態切換、按壓回饋。
        static let quick: TimeInterval = 0.18
        /// 版面變化、進出場。
        static let standard: TimeInterval = 0.25
        /// 卡片翻面。
        static let flip: TimeInterval = 0.5
        static let springDamping: CGFloat = 0.7
    }

    // MARK: - 觸覺

    /// 「只有證據支撐的時刻才震」——全 app 觸覺的唯一入口。
    ///
    /// 有資格觸發的時刻（規範 §7）：對方裝置確認收到（證件出示與 ZK
    /// 傳送）、領卡成功、查驗判定出爐、解鎖失敗、QR 掃描鎖定。
    /// 裝飾性 haptic（翻卡、展開）維持不做。
    enum Haptic {
        /// 有證據的成功：藍牙 ACK、新卡入庫。
        static func delivered() {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        /// 有證據的失敗：判定拒絕、解鎖失敗。
        static func rejected() {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        /// 掃描器鎖定一個 QR 的那一刻。
        static func scanLocked() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Navigation bar 政策
    //
    // 不覆寫全域 UINavigationBarAppearance——系統樣式就是規格。層級政策
    // 只有一條：root 畫面可用 large title；push 進去的畫面在自己的
    // `navigationItem.largeTitleDisplayMode` 設 `.never`，**絕不**翻共用
    // navigation bar 的 `prefersLargeTitles`——那會在 pop 回上一頁後留下
    // 錯的狀態，正是「push 鏈上樣式會跳」的來源。
}

extension Bonds {
    /// 可讀寬度：iPhone 上吃滿版寬減頁邊距；更寬的版面（iPad 查驗方畫面）
    /// 置中並封頂 640pt——查驗畫面在 iPad 上原本是 iPhone 版拉滿整個寬度，
    /// 一行字九十個字元。取代「leading/trailing 釘死 ±20」的水平約束組。
    static func readableHorizontal(_ view: UIView,
                                   in guide: UILayoutGuide) -> [NSLayoutConstraint] {
        let fill = view.widthAnchor.constraint(equalTo: guide.widthAnchor,
                                               constant: -2 * Space.page)
        // 低於 required：窄螢幕由它撐滿，寬螢幕讓位給 640 上限。
        fill.priority = .defaultHigh
        return [
            view.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor,
                                          constant: Space.page),
            fill,
        ]
    }
}

extension UIView {
    /// 依 accessibilityIdentifier 找子視圖——給「判定出爐時把 VoiceOver
    /// 游標停到判定卡上」這類收尾動作用。
    func firstSubview(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.firstSubview(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
