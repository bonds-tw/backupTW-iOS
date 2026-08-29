//
//  WalletCardCell.swift
//  backupTW
//
//  The collection-view cell that carries one `WalletCardView`, sizes itself to
//  the card's aspect ratio, and gives the press feedback a tappable card needs.
//

import UIKit

/// A full-width cell holding one wallet card. Self-sizes: the width comes from
/// the layout, the height from the card's aspect ratio.
final class WalletCardCell: UICollectionViewCell {

    static let reuseIdentifier = "WalletCardCell"

    private let cardView = WalletCardView()
    /// The height constraint driven by the current content's aspect ratio, so a
    /// flatter vault card is shorter than the 1.585 credential cards.
    private var aspectConstraint: NSLayoutConstraint?
    /// Pins the card to the cell's bottom in the normal (self-sizing) mode. In the
    /// collapsed-stack **peek** mode it is deactivated so the card keeps its full
    /// aspect height, pinned to the top, and overflows a short cell that clips it —
    /// leaving only the card's header (kind + issuer) showing.
    private var bottomConstraint: NSLayoutConstraint?

    /// A collapsed-stack peek shows only the card's header strip. `nil` in the
    /// normal full-card mode.
    private(set) var stackPeekHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)
        let bottom = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
        ])
        bottomConstraint = bottom
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ content: WalletCardContent) {
        cardView.configure(content)
        aspectConstraint?.isActive = false
        // height = width / ratio, driven off the card's own aspect ratio.
        let constraint = cardView.heightAnchor.constraint(
            equalTo: cardView.widthAnchor, multiplier: 1 / cardView.aspectRatio)
        // Below required so a momentary layout pass during reuse cannot conflict
        // with the width the compositional group hands the cell.
        constraint.priority = .required - 1
        constraint.isActive = true
        aspectConstraint = constraint
    }

    /// Switches the cell between the normal full-card mode (`nil`) and a
    /// collapsed-stack peek that shows only a `height`-tall header strip. In peek
    /// mode the bottom pin is released so the card keeps its full aspect height and
    /// the (layout-sized) cell clips it; a peek is not tappable-to-flip, so the
    /// press spring is left alone but the home screen routes its tap to expand.
    func setStackPeek(_ height: CGFloat?) {
        stackPeekHeight = height
        let isPeek = height != nil
        bottomConstraint?.isActive = !isPeek
        contentView.clipsToBounds = isPeek
        clipsToBounds = isPeek
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        // A collapsed-stack peek takes exactly the height its layout item gives it
        // — the full-height card overflows and is clipped — so it must not self-size
        // up to the whole card. The normal full card keeps self-sizing.
        if stackPeekHeight != nil { return layoutAttributes }
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    // MARK: - Phase 2a passthrough (gyroscope tilt)
    //
    // The home screen owns the one motion stream and fans each update out to its
    // visible cells; the cell just forwards to its card. The press spring
    // (`cardView.transform`, affine) and the tilt (`faceContainer.layer.transform`,
    // 3D) live on different layers, so they compose without fighting.

    func applyTilt(x: CGFloat, y: CGFloat) {
        cardView.applyTilt(x: x, y: y)
    }

    func resetTilt() {
        cardView.resetTilt()
    }

    // MARK: - Phase 2b passthrough (flip)
    //
    // The flip lives on the card's `flipNode`, a different layer again from both
    // the press spring and the tilt, so all three compose. The card zeroes and
    // pauses its own tilt while the back shows.

    /// Whether this card has a back worth turning to — the home screen asks before
    /// choosing flip over tap-through.
    var canFlip: Bool { cardView.hasBackContent }

    var isFlipped: Bool { cardView.isFlipped }

    func toggleFlip() {
        cardView.setFlipped(!cardView.isFlipped, animated: true)
    }

    /// Wired by the home screen to the back's 「view / manage details」 button.
    var onDetailTapped: (() -> Void)? {
        get { cardView.onDetailTapped }
        set { cardView.onDetailTapped = newValue }
    }

    // MARK: - Press feedback
    //
    // A card is a tappable object, so it acknowledges the finger: a small spring
    // scale-down on touch, released on lift or cancel. Kept on the cell rather
    // than the card view because the cell is what the collection view tracks, and
    // this is presentation, not content. The Phase 2 tilt/flip lives on the card
    // view's `faceContainer`; this does not touch it.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setPressed(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.18 : 0.34,
                       delay: 0,
                       usingSpringWithDamping: 0.7,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.cardView.transform = pressed ? CGAffineTransform(scaleX: 0.972, y: 0.972) : .identity
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setStackPeek(nil)   // back to a full, self-sizing card
        cardView.transform = .identity
        // A reused cell must show its front and carry neither the previous card's
        // flip nor its tilt into new content: reset the flip first (so it lands on
        // the front without animating), then clear the 3D tilt and press affine.
        cardView.setFlipped(false, animated: false)
        cardView.resetTilt()
        cardView.onDetailTapped = nil
    }
}
