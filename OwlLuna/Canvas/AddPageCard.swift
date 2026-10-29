import UIKit

/// Under the last page on an iPhone: a dashed outline as wide as the page that adds a page at the end.
final class AddPageCard: UIButton {
    private let outline = CAShapeLayer()

    init(action: @escaping () -> Void) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline))
        configuration.title = String(localized: "Add Page")
        configuration.imagePadding = Space.x2
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        self.configuration = configuration
        configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = .ink
            button.configuration?.background.backgroundColor = button.isHighlighted ? .well : .clear
        }
        outline.fillColor = nil
        outline.lineWidth = 1
        outline.lineDashPattern = [5, 4]
        layer.insertSublayer(outline, at: 0)
        addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        accessibilityIdentifier = "editor.addPage"
        isPointerInteractionEnabled = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (card: AddPageCard, _) in
            card.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = bounds
        outline.path = UIBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        outline.strokeColor = UIColor.hairline.resolvedColor(with: traitCollection).cgColor
    }
}
