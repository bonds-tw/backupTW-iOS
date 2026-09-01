//
//  DiscloseFieldsViewController.swift
//  backupTW
//
//  The one screen where the holder decides what a verifier gets to see.
//

import UIKit

/// Lists the claims a verifier asked for, each a switch the holder can turn off,
/// and sends only the ones left on.
///
/// # Why every row starts on, and can be turned off
///
/// The request names the fields the verifier wants; answering with fewer is the
/// selective disclosure this whole wallet exists to make easy. So each requested
/// claim is a row that is **on** by default — the honest starting point is "give
/// what was asked" — and turning one off withholds exactly that claim while the
/// issuer's signature over the rest still verifies. Nothing here can add a claim
/// the verifier did not ask for; the switches only ever remove.
///
/// # What is not a switch
///
/// A requested field whose path is not a plain `$.credentialSubject.<name>` —
/// `$.type`, say — is a constraint on which card matches, not a disclosable
/// claim, so it is not shown as something to reveal or withhold. Only fields with
/// a `claimName` become rows.
final class DiscloseFieldsViewController: UITableViewController {

    private let request: OID4VPRequest
    private let requestFetchMilliseconds: UInt64?
    /// The disclosable claims, in the order the verifier listed them.
    private let claims: [String]
    /// Claim name → whether it is currently on. Starts all-on.
    private var revealing: [String: Bool]

    private let presentButton = UIButton(type: .system)

    #if DEBUG
    /// What each stored TWDIW card can actually disclose — so a "the card doesn't
    /// have this field" failure can be diagnosed against the real card's own claim
    /// names, not the demo card's. Read once, off the real store.
    private lazy var debugCardInventory: String = {
        guard let store = try? CredentialStore() else { return "no store" }
        var lines: [String] = []
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id) else { continue }
            if StoredCardSource.source(of: serialized) == .twdiw,
               let credential = try? TWDIWCredentialReader.read(serialized) {
                let names = credential.disclosedClaims.map(\.name).joined(separator: ", ")
                lines.append("• \(credential.credentialType): [\(names)]")
            }
        }
        return lines.isEmpty ? "no TWDIW cards stored" : lines.joined(separator: "\n")
    }()
    #endif

    init(request: OID4VPRequest, requestFetchMilliseconds: UInt64? = nil) {
        self.request = request
        self.requestFetchMilliseconds = requestFetchMilliseconds
        self.claims = request.requestedFields.compactMap(\.claimName)
        self.revealing = Dictionary(uniqueKeysWithValues: claims.map { ($0, true) })
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Present a credential", comment: "disclosure screen title")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "claim")
        configurePresentButton()
    }

    private func configurePresentButton() {
        var config = UIButton.Configuration.filled()
        config.title = NSLocalizedString("Present", comment: "present button")
        config.cornerStyle = .large
        presentButton.configuration = config
        presentButton.addTarget(self, action: #selector(present(_:)), for: .touchUpInside)
        presentButton.translatesAutoresizingMaskIntoConstraints = false

        // A footer that holds the button off the last row and stays reachable.
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 88))
        footer.addSubview(presentButton)
        NSLayoutConstraint.activate([
            presentButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            presentButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 20),
            presentButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            presentButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            presentButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        tableView.tableFooterView = footer
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        claims.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        NSLocalizedString("A verifier is asking to see these. Turn off anything you would rather not show.",
                          comment: "disclosure header")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        // What withholding actually does, so the choice is informed rather than
        // decorative: the issuer's signature over the rest still holds.
        var footer = NSLocalizedString("What you leave off is never sent. The verifier can still check that the rest was issued by the official issuer and not changed.",
                                       comment: "disclosure footer")
        #if DEBUG
        footer += "\n\n[DEBUG] stored cards & their disclosable claims:\n" + debugCardInventory
        #endif
        return footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "claim", for: indexPath)
        let claim = claims[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = ClaimDisplayName.friendly(claim)
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = revealing[claim] ?? true
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc private func toggled(_ sender: UISwitch) {
        revealing[claims[sender.tag]] = sender.isOn
    }

    // MARK: - Present

    @objc private func present(_ sender: UIButton) {
        let chosen = Set(claims.filter { revealing[$0] ?? false })
        presentButton.isEnabled = false
        presentButton.configuration?.showsActivityIndicator = true

        Task { @MainActor in
            let started = VerificationClock.now()
            let outcome = await OID4VPPresentation.respond(to: request, disclosing: chosen)
            let submitMilliseconds = VerificationClock.milliseconds(
                from: started, to: VerificationClock.now())
            let record = VerificationRunRecord(
                flow: .oid4vpPresentation,
                role: .holder,
                credentialKind: .governmentWallet,
                transport: .https,
                succeeded: outcome.succeeded,
                preparationMilliseconds: requestFetchMilliseconds,
                endToEndMilliseconds: submitMilliseconds)
            try? VerificationRunStore.shared.append(record)
            self.finish(outcome: outcome.message,
                        submitMilliseconds: submitMilliseconds)
        }
    }

    /// Pops back to where the flow began and reports the outcome there.
    @MainActor
    private func finish(outcome: String, submitMilliseconds: UInt64) {
        let nav = navigationController
        nav?.popToRootViewController(animated: true)
        var timing: [String] = []
        if let requestFetchMilliseconds {
            timing.append(String(format: NSLocalizedString(
                "Request retrieval and verification: %.2f seconds",
                comment: "OID4VP request timing"),
                Double(requestFetchMilliseconds) / 1_000))
        }
        timing.append(String(format: NSLocalizedString(
            "Present to verifier response: %.2f seconds (wallet signing, network, and verifier processing)",
            comment: "OID4VP end-to-end timing"),
            Double(submitMilliseconds) / 1_000))
        let message = ([outcome] + timing).joined(separator: "\n\n")
        let alert = UIAlertController(title: NSLocalizedString("Present a credential", comment: ""),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))

        var presenter: UIViewController? = nav
        while let presented = presenter?.presentedViewController { presenter = presented }
        (presenter ?? nav?.topViewController)?.present(alert, animated: true)
    }
}

/// Turns a TWDIW claim name into something a person reads. Falls back to the raw
/// name — a field this table did not anticipate is still shown, never hidden,
/// because a hidden field is one the holder cannot decide about.
enum ClaimDisplayName {
    static func friendly(_ claim: String) -> String {
        let map: [String: String] = [
            "name": NSLocalizedString("Name", comment: "claim: name"),
            "id_number": NSLocalizedString("National ID number", comment: "claim: id number"),
            "roc_birthday": NSLocalizedString("Date of birth", comment: "claim: birthday"),
            "Phone_number_last3": NSLocalizedString("Last 3 digits of phone number", comment: "claim: phone last 3"),
            "phone_number_last3": NSLocalizedString("Last 3 digits of phone number", comment: "claim: phone last 3"),
            "phonel3": NSLocalizedString("Last 3 digits of phone number", comment: "claim: phone last 3"),
            "Phone_number_last5": NSLocalizedString("Last 5 digits of phone number", comment: "claim: phone last 5"),
            "phone_number_last5": NSLocalizedString("Last 5 digits of phone number", comment: "claim: phone last 5"),
            "phonel5": NSLocalizedString("Last 5 digits of phone number", comment: "claim: phone last 5"),
            "type": NSLocalizedString("Licence type", comment: "claim: licence type"),
            "controlnumber": NSLocalizedString("Control number", comment: "claim: control number"),
            "gDate": NSLocalizedString("Date of issue", comment: "claim: issue date"),
        ]
        return map[claim] ?? claim
    }
}
