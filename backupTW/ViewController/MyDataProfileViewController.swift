//
//  MyDataProfileViewController.swift
//  backupTW
//

import UIKit

/// The holder explicitly manages MyData autofill here. Nothing is learned from
/// or scraped out of the government page, and the two fields never appear in a
/// glanceable list: they are masked native controls backed by a this-device-only
/// Keychain item.
final class MyDataProfileViewController: UITableViewController {
    private let nationalIDField = UITextField()
    private let birthDateField = UITextField()
    private let onChange: (() -> Void)?

    init(onChange: (() -> Void)? = nil) {
        self.onChange = onChange
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("MyData remembered details", comment: "MyData profile title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Save", comment: ""), style: .done,
            target: self, action: #selector(save))

        configure(nationalIDField,
                  placeholder: NSLocalizedString("Taiwan national ID number", comment: "MyData profile field"),
                  keyboard: .asciiCapable)
        nationalIDField.autocapitalizationType = .allCharacters
        configure(birthDateField,
                  placeholder: NSLocalizedString("Birth date (YYYYMMDD)", comment: "MyData profile field"),
                  keyboard: .numberPad)

        if let profile = MyDataAutofillProfileStore.load() {
            nationalIDField.text = profile.nationalIDNumber
            birthDateField.text = profile.birthDate
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("Forget", comment: "MyData profile"), style: .plain,
                target: self, action: #selector(confirmForget))
        }
        tableView.keyboardDismissMode = .interactive
    }

    private func configure(_ field: UITextField, placeholder: String,
                           keyboard: UIKeyboardType) {
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.isSecureTextEntry = true
        field.textContentType = nil
        field.accessibilityLabel = placeholder
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : 1
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? NSLocalizedString("Details to fill on MyData", comment: "MyData profile section")
            : NSLocalizedString("Stored on this iPhone", comment: "MyData profile section")
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return NSLocalizedString(
            "These details stay in the iOS Keychain on this iPhone. They are filled only on the official mydata.nat.gov.tw site, never sent to Bonds or included in backup.",
            comment: "MyData profile privacy explanation")
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let field = indexPath.row == 0 ? nationalIDField : birthDateField
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11),
            ])
            cell.selectionStyle = .none
        } else {
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "lock.shield.fill")
            content.text = NSLocalizedString("Keychain · this device only", comment: "MyData profile storage")
            content.secondaryText = NSLocalizedString("Available only while this iPhone is unlocked", comment: "MyData profile storage")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
        }
        return cell
    }

    @objc private func save() {
        do {
            let profile = try MyDataAutofillProfile(
                nationalIDNumber: nationalIDField.text ?? "",
                birthDate: birthDateField.text ?? "")
            try MyDataAutofillProfileStore.save(profile)
            onChange?()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(
                title: NSLocalizedString("Could not save remembered details", comment: "MyData profile error"),
                message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
            present(alert, animated: true)
        }
    }

    @objc private func confirmForget() {
        let alert = UIAlertController(
            title: NSLocalizedString("Forget MyData details?", comment: "MyData profile delete"),
            message: NSLocalizedString("The saved ID number and birth date will be removed from this iPhone.", comment: "MyData profile delete"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Forget", comment: "MyData profile delete"),
                                      style: .destructive) { [weak self] _ in
            try? MyDataAutofillProfileStore.delete()
            self?.onChange?()
            self?.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }
}
