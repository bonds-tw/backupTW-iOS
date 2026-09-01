//
//  MyDataCredentialUseCasesViewController.swift
//  backupTW
//

import UIKit

/// A product boundary, not a pretend issuer.
///
/// A downloaded MyData PDF is useful evidence, but it is not automatically a
/// government-signed VC. This screen makes the useful next step concrete while
/// keeping that distinction visible: derive a small claim from an integrity-
/// checked source, let the holder choose it, then make the verifier name it as a
/// holder-derived claim. The app does not expose an inert 「mint」 button until a
/// parser and verifier for the particular document schema actually exist.
final class MyDataCredentialUseCasesViewController: UIViewController {

    private let documentTitle: String

    init(documentTitle: String) {
        self.documentTitle = documentTitle
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString("Selective-disclosure scenarios", comment: "MyData VC scenarios title")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16

        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        stack.addArrangedSubview(makeCard(
            title: documentTitle,
            body: NSLocalizedString(
                "The original stays in your vault. A future credential should disclose only the answer a verifier needs, not attach this whole document.",
                comment: "MyData VC source card"),
            symbol: "doc.text.magnifyingglass",
            tint: .systemBlue))

        stack.addArrangedSubview(makeHeading(NSLocalizedString(
            "Good first test scenarios", comment: "MyData VC scenarios heading")))
        stack.addArrangedSubview(makeCard(
            title: NSLocalizedString("Income qualification", comment: "MyData VC scenario"),
            body: NSLocalizedString(
                "For a rental or benefit application, reveal the tax year and whether income falls inside the requested range — not the exact amount or every payer.",
                comment: "MyData VC scenario"),
            symbol: "banknote.fill", tint: .systemGreen))
        stack.addArrangedSubview(makeCard(
            title: NSLocalizedString("Insurance status", comment: "MyData VC scenario"),
            body: NSLocalizedString(
                "Prove coverage was active on a requested date without revealing employer history, salary basis, or unrelated periods.",
                comment: "MyData VC scenario"),
            symbol: "shield.checkered", tint: .systemTeal))
        stack.addArrangedSubview(makeCard(
            title: NSLocalizedString("Residence or property predicate", comment: "MyData VC scenario"),
            body: NSLocalizedString(
                "Prove a city, district, residence, or ownership condition without exposing a complete address, household, parcel, or encumbrance record.",
                comment: "MyData VC scenario"),
            symbol: "house.fill", tint: .systemOrange))

        stack.addArrangedSubview(makeHeading(NSLocalizedString(
            "What the verifier must show", comment: "MyData VC trust heading")))
        stack.addArrangedSubview(makeCard(
            title: NSLocalizedString("Holder-derived evidence", comment: "MyData VC trust label"),
            body: NSLocalizedString(
                "A PDF downloaded from MyData is not automatically a government-issued VC. The verifier must label the claim as derived and signed by the holder, show the source-file fingerprint and extraction rules, and never display a government-issued badge unless an authority signature was actually verified.",
                comment: "MyData VC trust explanation"),
            symbol: "person.badge.shield.checkmark", tint: .systemPurple))
        stack.addArrangedSubview(makeCard(
            title: NSLocalizedString("Pilot readiness", comment: "MyData VC readiness"),
            body: NSLocalizedString(
                "Before enabling creation, each document type needs a tested parser, stable claim definitions, selective-disclosure signing, and matching verification at verifier.mashbean.net. Export and sharing are available now; credential creation stays gated until those checks exist.",
                comment: "MyData VC readiness"),
            symbol: "checklist", tint: .systemGray))
    }

    private func makeHeading(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func makeCard(title: String, body: String, symbol: String, tint: UIColor) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        let bodyLabel = UILabel()
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 0
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.text = body

        let text = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        text.axis = .vertical
        text.spacing = 6
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .top
        row.spacing = 12

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }
}
