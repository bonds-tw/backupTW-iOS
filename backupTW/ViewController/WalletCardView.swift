//
//  WalletCardView.swift
//  backupTW
//
//  The Apple-Wallet-style card face for the home screen.
//
//  # What this view is, and what it deliberately is not
//
//  It draws one card face from a `WalletCardContent`, and nothing more. Every
//  struct it takes carries *already-masked display strings* — this view never
//  sees a raw 統一編號, a full 門號, or a birthdate, because the one surface in
//  this app most likely to be read over a shoulder must not be the one that
//  leaks them. Masking is `WalletCardMask`'s job and is a pure, tested function;
//  choosing which fields even reach a card is `WalletCardFactory`'s. By the time
//  a string arrives here the decision that it is safe to glance at has already
//  been made and tested somewhere it can be.
//
//  # The Phase 2 seam
//
//  This is Phase 1: static faces, press feedback (on the cell), tap-through to
//  detail. The reflective sheen that the design drives from CoreMotion, the
//  flip-to-back, and the government stack's fan-out are Phase 2. Rather than
//  bolt those on later against a view with no room for them, the seam is left
//  open now: `shineLayer` is a real (currently static) sublayer sitting above
//  the face art and below the text, exactly where a motion-driven specular
//  highlight goes, and `faceContainer` is the single node a flip transform will
//  rotate. Neither is animated here.
//

import UIKit

// MARK: - Content model

/// What a single wallet card shows. Each case carries only display-ready,
/// already-masked strings.
enum WalletCardContent: Hashable {
    case nationalID(NationalIDCard)
    case credential(CredentialCard)
    case vault(VaultCard)
    /// The store would not open, or the card would not decode. A neutral face
    /// carrying the one honest sentence — never dressed up as an empty wallet.
    case unreadable(String)
}

/// The 米色實體身分證 face: national flag emoji, guilloché stock, black text,
/// and the red 統一編號 pinned to the footer.
struct NationalIDCard: Hashable {
    /// e.g. 「中華民國國民身分證」.
    let title: String
    /// Shown in full. A name cannot be withheld from a document that carries it
    /// — see `CardCapability.selfIssued`'s limits — so masking it here would be
    /// a false promise rather than a protection. Empty on the placeholder card.
    let holderName: String
    /// Label + already-masked value rows, drawn as a two-column grid.
    let fields: [WalletCardField]
    /// The red footer's label (「統一編號」) and its masked value (e.g. A2●●●●●●●0).
    /// `nil` on the placeholder (invite-to-create) card, which has no number yet.
    let idLabel: String?
    let idValueMasked: String?
    /// When set, the card is an empty-state invitation rather than a real
    /// document: the grid and the red number are replaced by this prompt.
    let placeholderMessage: String?
    /// Where this card's trust comes from, drawn as a small line above the field
    /// grid. For the self-issued ID this is 「行動自然人憑證 · 本人自簽」 — the honest
    /// statement that nobody vouches for it but the holder. Empty to draw nothing.
    let trustSource: String

    init(title: String,
         holderName: String,
         fields: [WalletCardField] = [],
         idLabel: String? = nil,
         idValueMasked: String? = nil,
         placeholderMessage: String? = nil,
         trustSource: String = "") {
        self.title = title
        self.holderName = holderName
        self.fields = fields
        self.idLabel = idLabel
        self.idValueMasked = idValueMasked
        self.placeholderMessage = placeholderMessage
        self.trustSource = trustSource
    }
}

/// The green / magenta modern credential face: kind leads, issuer in small faint
/// type, holder + primary number in the middle, two fields at the foot.
struct CredentialCard: Hashable {
    /// The card's kind, from the credential's own type string — never a name
    /// this app invented for it. See `CardInventory.readableType`.
    let kind: String
    /// A small all-caps English line under the kind, when one is known; `nil`
    /// otherwise rather than guessed.
    let kindEnglish: String?
    /// Who issued it, as small faint type. This is the issuer's own identifier
    /// (a DID), sanitised and shortened — offline, this app has no friendly name
    /// for an issuer and refuses to invent one, so it shows the honest thing.
    let issuer: String
    let holderName: String?
    /// The card's primary number, already masked (never a full ID or 門號).
    let primaryMasked: String?
    /// Where this card's trust comes from — for a government card, the curated
    /// 「數位發展部信任清單」 that let it into the wallet. Drawn as a small line
    /// above the foot fields. Empty to draw nothing.
    let trustSource: String
    let leftField: WalletCardField?
    let rightField: WalletCardField?
    let tint: WalletCardTint
}

/// The 石墨 MyData 資料保險箱 face: a lock in a tinted tile, a status dot, and the
/// standing note that nothing is kept here.
struct VaultCard: Hashable {
    let title: String
    let message: String
    /// e.g. 「已封存」.
    let status: String
}

/// One label/value pair on a card face. The value is already masked when it
/// stands for something sensitive.
struct WalletCardField: Hashable {
    let label: String
    let value: String
}

/// The card's colour identity. A stable, deliberately small palette chosen by
/// `WalletCardFactory` from the card's kind — a colour is not a claim, so this
/// is the one place a kind may steer presentation without asserting anything.
enum WalletCardTint: Hashable {
    /// 駕照 / 公路局 and other transport cards.
    case green
    /// 電信 門號電子卡.
    case magenta
    /// Anything else recognised as a credential.
    case neutral

    /// Top-left → bottom-right gradient stops, matching the design's linear
    /// gradients at ~150°.
    var gradientColors: [CGColor] {
        switch self {
        case .green:
            return [UIColor(red: 0x13/255, green: 0x7a/255, blue: 0x5d/255, alpha: 1).cgColor,
                    UIColor(red: 0x0d/255, green: 0x5b/255, blue: 0x48/255, alpha: 1).cgColor,
                    UIColor(red: 0x08/255, green: 0x3a/255, blue: 0x30/255, alpha: 1).cgColor]
        case .magenta:
            return [UIColor(red: 0xd6/255, green: 0x1f/255, blue: 0x83/255, alpha: 1).cgColor,
                    UIColor(red: 0x9c/255, green: 0x2a/255, blue: 0x9e/255, alpha: 1).cgColor,
                    UIColor(red: 0x5b/255, green: 0x2d/255, blue: 0x9c/255, alpha: 1).cgColor]
        case .neutral:
            return [UIColor(red: 0x3a/255, green: 0x3d/255, blue: 0x46/255, alpha: 1).cgColor,
                    UIColor(red: 0x2a/255, green: 0x2c/255, blue: 0x33/255, alpha: 1).cgColor,
                    UIColor(red: 0x1c/255, green: 0x1d/255, blue: 0x22/255, alpha: 1).cgColor]
        }
    }

    /// The soft top-right specular highlight baked into the design's gradients
    /// (rgba(150,255,214,.42) for green, rgba(255,180,236,.5) for magenta).
    var highlightColor: UIColor {
        switch self {
        case .green: return UIColor(red: 150/255, green: 1, blue: 214/255, alpha: 0.42)
        case .magenta: return UIColor(red: 1, green: 180/255, blue: 236/255, alpha: 0.5)
        case .neutral: return UIColor(white: 1, alpha: 0.14)
        }
    }
}

// MARK: - The view

/// Draws one `WalletCardContent`. Rebuilds its subviews on each `configure`.
final class WalletCardView: UIView {

    /// The node a Phase 2 flip transform will rotate; all face art and text live
    /// inside it. Kept as one layer boundary now so the flip has a single thing
    /// to animate later.
    private let faceContainer = UIView()

    /// The card's background art (gradient / paper). Redrawn per content.
    private let backgroundLayer = CAGradientLayer()
    /// The baked-in top-right highlight for tinted cards.
    private let highlightLayer = CAGradientLayer()

    /// # Phase 2 seam — the moving specular sheen.
    ///
    /// The design drives a radial highlight from the device gyroscope. This is
    /// that highlight's home: a sublayer above the face art and below the text,
    /// static in Phase 1 (a faint fixed glint), repositioned by CoreMotion in
    /// Phase 2. It is created and inserted now so the later change is a value
    /// update on an existing layer rather than a re-layering of the view.
    private let shineLayer = CAGradientLayer()

    /// The pale-green rosette guilloché, only on the national ID paper face.
    private let guilloche = WalletGuillocheView()

    /// The current content's aspect ratio, so the cell can size to it.
    private(set) var aspectRatio: CGFloat = 1.585

    private var contentSubviews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        // The card's own drop shadow. Kept off the clipped face container so the
        // shadow is not clipped away with the art.
        layer.shadowColor = UIColor(red: 18/255, green: 22/255, blue: 40/255, alpha: 1).cgColor
        layer.shadowOpacity = 0.30
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 14)

        faceContainer.layer.cornerRadius = Self.cornerRadius
        faceContainer.layer.cornerCurve = .continuous
        faceContainer.clipsToBounds = true
        faceContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(faceContainer)
        NSLayoutConstraint.activate([
            faceContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            faceContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            faceContainer.topAnchor.constraint(equalTo: topAnchor),
            faceContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        backgroundLayer.needsDisplayOnBoundsChange = true
        faceContainer.layer.addSublayer(backgroundLayer)
        faceContainer.layer.addSublayer(highlightLayer)

        guilloche.translatesAutoresizingMaskIntoConstraints = false
        guilloche.isUserInteractionEnabled = false
        faceContainer.addSubview(guilloche)
        NSLayoutConstraint.activate([
            guilloche.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor),
            guilloche.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor),
            guilloche.topAnchor.constraint(equalTo: faceContainer.topAnchor),
            guilloche.bottomAnchor.constraint(equalTo: faceContainer.bottomAnchor),
        ])

        // The Phase 2 sheen. Its resting position is a faint fixed glint near the
        // top; CoreMotion slides it around this rest point in `applyTilt`, and
        // `resetTilt` brings it home. Rest points are named so both places agree.
        shineLayer.type = .radial
        shineLayer.startPoint = Self.shineRestStart
        shineLayer.endPoint = Self.shineRestEnd
        shineLayer.colors = [UIColor(white: 1, alpha: 0.12).cgColor,
                             UIColor(white: 1, alpha: 0).cgColor]
        faceContainer.layer.addSublayer(shineLayer)
    }

    static let cornerRadius: CGFloat = 20

    // MARK: Phase 2a — motion tuning

    /// The radial sheen's resting centre and radius-defining end point. The tilt
    /// translates both by the same delta, so the highlight moves as one rigid
    /// blob rather than smearing.
    private static let shineRestStart = CGPoint(x: 0.3, y: 0.15)
    private static let shineRestEnd = CGPoint(x: 1.1, y: 1.0)

    /// How far, in unit-square terms, the sheen slides at full tilt. Deliberately
    /// small — a light passing over the card, not a spotlight swinging across it.
    private static let shineTravel: CGFloat = 0.22

    /// The peak 3D rotation of the face at full tilt. 6° reads as depth without
    /// tipping into gimmick or revealing the clipped card edges.
    private static let maxTiltAngle: CGFloat = 6 * .pi / 180

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = faceContainer.bounds
        highlightLayer.frame = faceContainer.bounds
        shineLayer.frame = faceContainer.bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
        CATransaction.commit()
    }

    // MARK: Phase 2a — gyroscope sheen + micro-tilt

    /// Applies a live tilt from `WalletMotionCoordinator`. `x` and `y` are in
    /// [-1, 1]: x from device roll (left/right), y from pitch (toward/away).
    ///
    /// Two things move together, both with implicit animation off so each of the
    /// ~60 updates a second lands as a single cheap frame rather than queuing a
    /// pile of quarter-second layer animations that would stutter:
    ///   • the radial sheen slides opposite the tilt, as a fixed light would
    ///     appear to sweep across a card turned under it;
    ///   • `faceContainer` takes a small perspective rotation, so the whole face
    ///     — art, sheen and text as one node — leans with the phone.
    /// Nothing is rebuilt or re-laid-out here; this is pure per-frame value
    /// updates on layers that already exist.
    func applyTilt(x: CGFloat, y: CGFloat) {
        // Belt-and-suspenders: the coordinator already refuses to start under
        // Reduce Motion, but a card must never animate itself if that is on.
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let dx = x * Self.shineTravel
        let dy = y * Self.shineTravel
        shineLayer.startPoint = CGPoint(x: Self.shineRestStart.x + dx,
                                        y: Self.shineRestStart.y + dy)
        shineLayer.endPoint = CGPoint(x: Self.shineRestEnd.x + dx,
                                      y: Self.shineRestEnd.y + dy)

        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 700.0 // perspective; nearer edge grows, far shrinks
        transform = CATransform3DRotate(transform, x * Self.maxTiltAngle, 0, 1, 0)
        transform = CATransform3DRotate(transform, -y * Self.maxTiltAngle, 1, 0, 0)
        faceContainer.layer.transform = transform

        CATransaction.commit()
    }

    /// Returns the face to flat and the sheen to its rest point, with a short
    /// settle so releasing (leaving the screen, or losing the sensor) reads as
    /// the card coming to rest rather than snapping.
    func resetTilt() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        shineLayer.startPoint = Self.shineRestStart
        shineLayer.endPoint = Self.shineRestEnd
        faceContainer.layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Configuration

    func configure(_ content: WalletCardContent) {
        contentSubviews.forEach { $0.removeFromSuperview() }
        contentSubviews.removeAll()

        switch content {
        case .nationalID(let card):
            aspectRatio = 1.585
            buildNationalID(card)
        case .credential(let card):
            aspectRatio = 1.585
            buildCredential(card)
        case .vault(let card):
            aspectRatio = 1.9
            buildVault(card)
        case .unreadable(let message):
            aspectRatio = 1.585
            buildUnreadable(message)
        }
    }

    private func add(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        faceContainer.addSubview(view)
        contentSubviews.append(view)
    }

    // MARK: National ID (米色實體身分證)

    private func buildNationalID(_ card: NationalIDCard) {
        // Paper stock: a near-flat pale gradient, an inner hairline frame, and
        // the green rosette guilloché.
        backgroundLayer.colors = [UIColor(red: 0xf7/255, green: 0xf5/255, blue: 0xea/255, alpha: 1).cgColor,
                                  UIColor(red: 0xec/255, green: 0xea/255, blue: 0xdb/255, alpha: 1).cgColor]
        setDiagonalGradient()
        highlightLayer.colors = []
        faceContainer.layer.borderWidth = 1
        faceContainer.layer.borderColor = UIColor(red: 70/255, green: 60/255, blue: 30/255, alpha: 0.16).cgColor
        guilloche.isHidden = false
        shineLayer.opacity = 0.5

        let ink = UIColor(red: 0x21/255, green: 0x1e/255, blue: 0x15/255, alpha: 1)
        let label = UIColor(red: 0x5b/255, green: 0x55/255, blue: 0x45/255, alpha: 1)
        let hair = UIColor(red: 60/255, green: 50/255, blue: 22/255, alpha: 0.22)

        // Title row: 🇹🇼 + 中華民國國民身分證, with a hairline under it.
        let title = makeLabel(card.title, font: .systemFont(ofSize: 16, weight: .heavy), color: ink)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let flag = makeLabel("🇹🇼", font: .systemFont(ofSize: 17), color: ink)
        let titleRow = UIStackView(arrangedSubviews: [flag, title])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        add(titleRow)

        let titleHair = makeHairline(hair)
        add(titleHair)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: faceContainer.topAnchor, constant: 15),
            titleRow.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: faceContainer.trailingAnchor, constant: -18),
            titleHair.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 9),
            titleHair.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
            titleHair.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -18),
        ])

        if let message = card.placeholderMessage {
            // Empty-state invitation: no fields, no number.
            let prompt = makeLabel(message,
                                   font: .systemFont(ofSize: 14, weight: .medium),
                                   color: label)
            prompt.numberOfLines = 0
            add(prompt)
            NSLayoutConstraint.activate([
                prompt.topAnchor.constraint(equalTo: titleHair.bottomAnchor, constant: 16),
                prompt.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
                prompt.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -18),
                prompt.bottomAnchor.constraint(lessThanOrEqualTo: faceContainer.bottomAnchor, constant: -16),
            ])
            return
        }

        // Field grid: name first (shown), then the masked rows.
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        grid.alignment = .fill

        grid.addArrangedSubview(makeIDRow(labelText: NSLocalizedString("Name", comment: "id card face"),
                                          valueText: card.holderName,
                                          label: label, ink: ink,
                                          valueFont: .systemFont(ofSize: 18, weight: .bold),
                                          tracking: 3))
        for field in card.fields {
            grid.addArrangedSubview(makeIDRow(labelText: field.label,
                                              valueText: field.value,
                                              label: label, ink: ink,
                                              valueFont: .systemFont(ofSize: 13, weight: .semibold)))
        }
        add(grid)
        // Trust source above the grid: on the paper ID it reads
        // 「行動自然人憑證 · 本人自簽」 — the honest note that this document vouches
        // for itself. Grey rather than ink, so it stays quieter than the name.
        // A tighter gap than the tinted cards, since the paper face is the
        // vertically tightest of the three.
        let gridTop: NSLayoutConstraint
        if !card.trustSource.isEmpty {
            let trust = makeTrustLine(card.trustSource, color: label)
            add(trust)
            NSLayoutConstraint.activate([
                trust.topAnchor.constraint(equalTo: titleHair.bottomAnchor, constant: 8),
                trust.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
                trust.trailingAnchor.constraint(lessThanOrEqualTo: faceContainer.trailingAnchor, constant: -18),
            ])
            gridTop = grid.topAnchor.constraint(equalTo: trust.bottomAnchor, constant: 7)
        } else {
            gridTop = grid.topAnchor.constraint(equalTo: titleHair.bottomAnchor, constant: 11)
        }
        NSLayoutConstraint.activate([
            gridTop,
            grid.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -18),
        ])

        // Red 統一編號 footer: top hairline, right-aligned, monospaced.
        if let idLabel = card.idLabel, let idValue = card.idValueMasked {
            let uidHair = makeHairline(UIColor(red: 60/255, green: 50/255, blue: 22/255, alpha: 0.2))
            add(uidHair)
            let uidLabel = makeLabel(idLabel,
                                     font: .systemFont(ofSize: 10, weight: .semibold),
                                     color: UIColor(red: 0xb2/255, green: 0x33/255, blue: 0x24/255, alpha: 1))
            let uidValue = makeLabel(idValue,
                                     font: .monospacedSystemFont(ofSize: 19, weight: .bold),
                                     color: UIColor(red: 0xc0/255, green: 0x26/255, blue: 0x1f/255, alpha: 1))
            let uidRow = UIStackView(arrangedSubviews: [uidLabel, uidValue])
            uidRow.axis = .horizontal
            uidRow.spacing = 10
            uidRow.alignment = .firstBaseline
            add(uidRow)
            NSLayoutConstraint.activate([
                uidHair.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 18),
                uidHair.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -18),
                uidHair.bottomAnchor.constraint(equalTo: uidRow.topAnchor, constant: -9),
                uidRow.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -18),
                uidRow.bottomAnchor.constraint(equalTo: faceContainer.bottomAnchor, constant: -14),
                uidRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 8),
            ])
        } else {
            grid.bottomAnchor.constraint(lessThanOrEqualTo: faceContainer.bottomAnchor, constant: -14).isActive = true
        }
    }

    /// A 「label　value」 row for the ID grid, label left at a fixed width so the
    /// values line up in a column.
    private func makeIDRow(labelText: String, valueText: String,
                           label: UIColor, ink: UIColor,
                           valueFont: UIFont, tracking: CGFloat = 0) -> UIView {
        let labelView = makeLabel(labelText, font: .systemFont(ofSize: 11), color: label)
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true

        let valueView: UILabel
        if tracking > 0 {
            valueView = UILabel()
            valueView.attributedText = NSAttributedString(
                string: valueText,
                attributes: [.font: valueFont, .foregroundColor: ink, .kern: tracking])
        } else {
            valueView = makeLabel(valueText, font: valueFont, color: ink)
        }
        valueView.numberOfLines = 1
        valueView.adjustsFontSizeToFitWidth = true
        valueView.minimumScaleFactor = 0.7

        let row = UIStackView(arrangedSubviews: [labelView, valueView])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .firstBaseline
        return row
    }

    // MARK: Credential (綠 / 洋紅 現代憑證卡)

    private func buildCredential(_ card: CredentialCard) {
        backgroundLayer.colors = card.tint.gradientColors
        setDiagonalGradient()
        // Top-right specular highlight, matching the design's radial in the
        // gradient stack.
        highlightLayer.type = .radial
        highlightLayer.startPoint = CGPoint(x: 0.82, y: 0.05)
        highlightLayer.endPoint = CGPoint(x: 0.1, y: 0.6)
        highlightLayer.colors = [card.tint.highlightColor.cgColor,
                                 card.tint.highlightColor.withAlphaComponent(0).cgColor]
        faceContainer.layer.borderWidth = 0
        guilloche.isHidden = true
        shineLayer.opacity = 0.9

        let white = UIColor.white

        // Top: kind (bold), a small caps English line, the faint issuer.
        let kind = makeLabel(card.kind, font: .systemFont(ofSize: 19, weight: .heavy), color: white)
        kind.numberOfLines = 2
        let topStack = UIStackView(arrangedSubviews: [kind])
        topStack.axis = .vertical
        topStack.spacing = 2
        topStack.alignment = .leading
        if let english = card.kindEnglish {
            let en = UILabel()
            en.attributedText = NSAttributedString(
                string: english.uppercased(),
                attributes: [.font: UIFont.systemFont(ofSize: 8.5, weight: .semibold),
                             .foregroundColor: white.withAlphaComponent(0.62),
                             .kern: 1.6])
            topStack.addArrangedSubview(en)
        }
        let issuer = makeLabel(card.issuer, font: .systemFont(ofSize: 10, weight: .medium),
                               color: white.withAlphaComponent(0.72))
        issuer.numberOfLines = 1
        issuer.lineBreakMode = .byTruncatingMiddle
        topStack.setCustomSpacing(5, after: topStack.arrangedSubviews.last ?? kind)
        topStack.addArrangedSubview(issuer)
        add(topStack)

        // Middle: holder + primary number.
        let midStack = UIStackView()
        midStack.axis = .vertical
        midStack.spacing = 4
        midStack.alignment = .leading
        if let holder = card.holderName {
            midStack.addArrangedSubview(makeLabel(holder, font: .systemFont(ofSize: 16, weight: .bold), color: white))
        }
        if let primary = card.primaryMasked {
            let num = UILabel()
            num.attributedText = NSAttributedString(
                string: primary,
                attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                             .foregroundColor: white.withAlphaComponent(0.95),
                             .kern: 2])
            midStack.addArrangedSubview(num)
        }
        add(midStack)

        // Foot: two fields.
        let footStack = UIStackView()
        footStack.axis = .horizontal
        footStack.alignment = .bottom
        footStack.distribution = .equalSpacing
        if let left = card.leftField {
            footStack.addArrangedSubview(makeFieldColumn(left, color: white, alignRight: false))
        }
        if let right = card.rightField {
            footStack.addArrangedSubview(makeFieldColumn(right, color: white, alignRight: true))
        }
        add(footStack)

        // The trust-source line sits just above the foot fields — the first thing
        // read below the number, saying who vouches for the card. Drawn only when
        // there is a source to name.
        var midBottom: NSLayoutConstraint
        if !card.trustSource.isEmpty {
            let trust = makeTrustLine(card.trustSource, color: white)
            add(trust)
            NSLayoutConstraint.activate([
                trust.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 21),
                trust.trailingAnchor.constraint(lessThanOrEqualTo: faceContainer.trailingAnchor, constant: -21),
                trust.bottomAnchor.constraint(equalTo: footStack.topAnchor, constant: -8),
            ])
            midBottom = midStack.bottomAnchor.constraint(equalTo: trust.topAnchor, constant: -10)
        } else {
            midBottom = midStack.bottomAnchor.constraint(equalTo: footStack.topAnchor, constant: -14)
        }

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: faceContainer.topAnchor, constant: 19),
            topStack.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 21),
            topStack.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -21),

            midStack.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 21),
            midStack.trailingAnchor.constraint(lessThanOrEqualTo: faceContainer.trailingAnchor, constant: -21),
            midBottom,

            footStack.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 21),
            footStack.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -21),
            footStack.bottomAnchor.constraint(equalTo: faceContainer.bottomAnchor, constant: -18),
        ])
        if footStack.arrangedSubviews.isEmpty {
            // No foot fields: let the middle sit against the bottom padding.
            footStack.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
    }

    private func makeFieldColumn(_ field: WalletCardField, color: UIColor, alignRight: Bool) -> UIView {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: field.label.uppercased(),
            attributes: [.font: UIFont.systemFont(ofSize: 8.5, weight: .regular),
                         .foregroundColor: color.withAlphaComponent(0.6),
                         .kern: 1])
        let value = makeLabel(field.value, font: .systemFont(ofSize: 11, weight: .semibold), color: color)
        let stack = UIStackView(arrangedSubviews: [label, value])
        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = alignRight ? .trailing : .leading
        return stack
    }

    // MARK: Vault (石墨 MyData 保險箱)

    private func buildVault(_ card: VaultCard) {
        backgroundLayer.colors = WalletCardTint.neutral.gradientColors
        setDiagonalGradient()
        highlightLayer.colors = []
        faceContainer.layer.borderWidth = 1
        faceContainer.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        guilloche.isHidden = true
        shineLayer.opacity = 0.6

        let accent = UIColor(red: 0x5f/255, green: 0xe3/255, blue: 0xc0/255, alpha: 1)
        let ink = UIColor(red: 0xe7/255, green: 0xe9/255, blue: 0xef/255, alpha: 1)

        // Lock tile — SF Symbol, a standard UI glyph, in a rounded tinted square.
        let lockTile = UIView()
        lockTile.backgroundColor = accent.withAlphaComponent(0.12)
        lockTile.layer.cornerRadius = 11
        lockTile.layer.cornerCurve = .continuous
        lockTile.layer.borderWidth = 1
        lockTile.layer.borderColor = accent.withAlphaComponent(0.3).cgColor
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = accent
        lock.contentMode = .scaleAspectFit
        lock.translatesAutoresizingMaskIntoConstraints = false
        lockTile.addSubview(lock)
        add(lockTile)
        NSLayoutConstraint.activate([
            lockTile.widthAnchor.constraint(equalToConstant: 38),
            lockTile.heightAnchor.constraint(equalToConstant: 38),
            lock.centerXAnchor.constraint(equalTo: lockTile.centerXAnchor),
            lock.centerYAnchor.constraint(equalTo: lockTile.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 18),
        ])

        // Status: a filled dot + 已封存 in caps.
        let dot = UIView()
        dot.backgroundColor = accent
        dot.layer.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let status = UILabel()
        status.attributedText = NSAttributedString(
            string: card.status,
            attributes: [.font: UIFont.systemFont(ofSize: 10, weight: .bold),
                         .foregroundColor: accent, .kern: 1.6])
        let statusRow = UIStackView(arrangedSubviews: [dot, status])
        statusRow.axis = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .center
        add(statusRow)

        let title = makeLabel(card.title, font: .systemFont(ofSize: 19, weight: .bold), color: ink)
        title.numberOfLines = 2
        add(title)
        let message = makeLabel(card.message, font: .systemFont(ofSize: 11.5), color: UIColor(red: 0xa6/255, green: 0xab/255, blue: 0xb7/255, alpha: 1))
        message.numberOfLines = 0
        add(message)

        NSLayoutConstraint.activate([
            lockTile.topAnchor.constraint(equalTo: faceContainer.topAnchor, constant: 20),
            lockTile.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 22),
            statusRow.centerYAnchor.constraint(equalTo: lockTile.centerYAnchor),
            statusRow.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -22),

            message.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 22),
            message.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -22),
            message.bottomAnchor.constraint(equalTo: faceContainer.bottomAnchor, constant: -20),
            title.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -22),
            title.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -6),
            title.topAnchor.constraint(greaterThanOrEqualTo: lockTile.bottomAnchor, constant: 12),
        ])
    }

    // MARK: Unreadable (中性面)

    private func buildUnreadable(_ message: String) {
        backgroundLayer.colors = WalletCardTint.neutral.gradientColors
        setDiagonalGradient()
        highlightLayer.colors = []
        faceContainer.layer.borderWidth = 1
        faceContainer.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        guilloche.isHidden = true
        shineLayer.opacity = 0.3

        let icon = UIImageView(image: UIImage(systemName: "externaldrive.badge.exclamationmark"))
        icon.tintColor = UIColor.systemOrange
        icon.contentMode = .scaleAspectFit
        add(icon)
        let label = makeLabel(message, font: .systemFont(ofSize: 13, weight: .medium),
                              color: UIColor(white: 0.9, alpha: 1))
        label.numberOfLines = 0
        add(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: faceContainer.topAnchor, constant: 20),
            icon.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 22),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: faceContainer.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: faceContainer.trailingAnchor, constant: -22),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: faceContainer.bottomAnchor, constant: -20),
        ])
    }

    // MARK: Helpers

    /// ~150° in the design: top-left biased down to bottom-right.
    private func setDiagonalGradient() {
        backgroundLayer.startPoint = CGPoint(x: 0.1, y: 0.0)
        backgroundLayer.endPoint = CGPoint(x: 0.85, y: 1.0)
    }

    /// The 「信任來源 · <值>」 line: a small, quiet label word and the source value,
    /// on one line. The prefix is the fainter of the two — it is chrome; the value
    /// is what the reader wants. `color` is the card's ink (white on tinted cards,
    /// a warm grey on the paper ID); the prefix is drawn at a lower alpha of it.
    private func makeTrustLine(_ value: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let prefix = NSLocalizedString("Trust source", comment: "wallet card: where a card's trust comes from")
        let text = NSMutableAttributedString(
            string: prefix + "  ",
            attributes: [.font: UIFont.systemFont(ofSize: 8.5, weight: .semibold),
                         .foregroundColor: color.withAlphaComponent(0.55),
                         .kern: 0.8])
        text.append(NSAttributedString(
            string: value,
            attributes: [.font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: color.withAlphaComponent(0.85)]))
        label.attributedText = text
        return label
    }

    private func makeLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 1
        return label
    }

    private func makeHairline(_ color: UIColor) -> UIView {
        let line = UIView()
        line.backgroundColor = color
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

// MARK: - Guilloché

/// The fine rosette security texture the real 身分證 stock is printed on — a
/// generated pattern, never an official emblem. Overlapping roses
/// `r = base + amp·sin(kθ)` at a few frequencies, tinted pale green, tiled across
/// the face. Ported from the design's canvas routine; drawn in `draw(_:)` so it
/// scales with the card rather than baking a fixed-size bitmap.
private final class WalletGuillocheView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let tint = (r: CGFloat(66) / 255, g: CGFloat(116) / 255, b: CGFloat(82) / 255)
        let gx: CGFloat = 60, gy: CGFloat = 58, base: CGFloat = 29, amp: CGFloat = 6.5
        context.setLineWidth(0.5)

        var ox: CGFloat = 8
        while ox < rect.width + gx {
            var oy: CGFloat = 6
            while oy < rect.height + gy {
                for (i, k) in [6.0, 9.0, 13.0].enumerated() {
                    let alpha = 0.12 - CGFloat(i) * 0.028
                    context.setStrokeColor(red: tint.r, green: tint.g, blue: tint.b, alpha: alpha)
                    let path = CGMutablePath()
                    var a: CGFloat = 0
                    var first = true
                    while a <= .pi * 2 + 0.02 {
                        let rad = base + amp * CGFloat(sin(k * Double(a)))
                            + (i > 0 ? amp * 0.4 * CGFloat(cos(Double(k - 2) * Double(a))) : 0)
                        let x = ox + rad * cos(a)
                        let y = oy + rad * sin(a)
                        if first { path.move(to: CGPoint(x: x, y: y)); first = false }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                        a += 0.035
                    }
                    path.closeSubpath()
                    context.addPath(path)
                    context.strokePath()
                }
                oy += gy
            }
            ox += gx
        }
    }
}
