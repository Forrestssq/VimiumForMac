import Cocoa

final class HintLabel: NSView {
    private let hint: String
    private var matchedPrefix: String = ""
    private let textField = NSTextField()

    init(frame: NSRect, hint: String) {
        self.hint = hint
        super.init(frame: frame)
        wantsLayer = true
        configureLayer()
        configureTextField()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Appearance

    private func configureLayer() {
        layer?.backgroundColor = NSColor(red: 1.0, green: 0.93, blue: 0.0, alpha: 0.96).cgColor
        layer?.cornerRadius    = 4
        layer?.borderColor     = NSColor(white: 0, alpha: 0.35).cgColor
        layer?.borderWidth     = 0.5
        layer?.shadowColor     = NSColor.black.cgColor
        layer?.shadowOpacity   = 0.55
        layer?.shadowOffset    = CGSize(width: 0, height: -1)
        layer?.shadowRadius    = 2.5
    }

    private func configureTextField() {
        textField.isBezeled       = false
        textField.isEditable      = false
        textField.isSelectable    = false
        textField.drawsBackground = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        renderText()
    }

    // MARK: - Filtering

    /// Highlight `prefix` chars as dimmed (already typed) and remaining chars as bold.
    func setMatchedPrefix(_ prefix: String) {
        matchedPrefix = prefix
        renderText()
    }

    private func renderText() {
        let attributed = NSMutableAttributedString()

        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let bright: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: NSColor.black,
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: NSColor(white: 0, alpha: 0.38),
        ]

        let prefixCount = matchedPrefix.count
        if prefixCount > 0 {
            let typed = String(hint.prefix(prefixCount))
            let rest  = String(hint.dropFirst(prefixCount))
            attributed.append(NSAttributedString(string: typed, attributes: dim))
            attributed.append(NSAttributedString(string: rest,  attributes: bright))
        } else {
            attributed.append(NSAttributedString(string: hint, attributes: bright))
        }

        textField.attributedStringValue = attributed
    }
}
