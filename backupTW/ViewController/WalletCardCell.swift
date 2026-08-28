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

    override init(frame: CGRect) {
        super.init(frame: frame)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
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
        cardView.transform = .identity
        // A reused cell must not carry the previous card's tilt into its new
        // content, so clear the 3D transform as well as the press affine.
        cardView.resetTilt()
    }
}
