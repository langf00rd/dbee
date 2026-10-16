import AppKit

/// Shared fonts, colours and sizes for the results grid.
@MainActor
enum GridMetrics {
    static let rowHeight: CGFloat = 22
    /// Label inset inside a data cell. NSTextField adds ~2pt of its own, so cell text starts where
    /// NSTableHeaderCell draws its title (~3pt) and header and values share one left edge.
    static let cellInset: CGFloat = 1
    /// Space after the right-aligned numbers in the row-number gutter.
    static let rowNumberTrailingInset: CGFloat = 5
    static let minColumnWidth: CGFloat = 44
    static let maxInitialColumnWidth: CGFloat = 320
    static let maxFittedColumnWidth: CGFloat = 800

    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let nullFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }()
    static let rowNumberFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    static let editedCellColor = NSColor.systemYellow.withAlphaComponent(0.3)
    static let insertedRowColor = NSColor.systemGreen.withAlphaComponent(0.16)
    static let deletedRowColor = NSColor.systemRed.withAlphaComponent(0.16)
}

/// Turns raw cell values into single-line display text.
enum GridText {
    /// Unicode scalars rendered in a cell. Laying out megabyte strings just to truncate them is expensive.
    static let displayLimit = 400
    /// Values up to this many UTF-8 bytes get their raw text as a tooltip when the cell can't show it faithfully.
    static let tooltipLimit = 2_000
    static let newlineSymbol: Unicode.Scalar = "\u{23CE}"

    struct Display: Equatable {
        var text: String
        /// The (scanned part of the) value contains line breaks, shown as ⏎.
        var isMultiline: Bool
        /// The value was longer than `displayLimit` and was cut.
        var isClipped: Bool
    }

    /// Line breaks become ⏎ (CRLF counts once), tabs become a space, and text past `limit` scalars is cut with "…".
    static func display(_ value: String, limit: Int = displayLimit) -> Display {
        let utf8 = value.utf8
        if utf8.count <= limit, !utf8.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return Display(text: value, isMultiline: false, isClipped: false)
        }
        var out = String.UnicodeScalarView()
        var count = 0
        var multiline = false
        var previousWasCR = false
        for scalar in value.unicodeScalars {
            if count >= limit {
                out.append("\u{2026}")
                return Display(text: String(out), isMultiline: multiline, isClipped: true)
            }
            switch scalar {
            case "\r":
                out.append(newlineSymbol)
                multiline = true
                previousWasCR = true
                count += 1
                continue
            case "\n":
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                out.append(newlineSymbol)
                multiline = true
            case "\t":
                out.append(" ")
            default:
                out.append(scalar)
            }
            previousWasCR = false
            count += 1
        }
        return Display(text: String(out), isMultiline: multiline, isClipped: false)
    }
}

/// Decides which columns hold numbers, so the grid can right-align them (Numbers / Finder convention).
enum GridNumeric {
    /// True for types whose values are plain numbers. Arrays and other containers (ClickHouse Array(…), CQL
    /// list<…>), ranges, intervals, geometric types, booleans (including MySQL's tinyint(1)) and mixed types
    /// (a Meilisearch field seen as "string | number") are excluded.
    static func isNumericType(_ dataType: String) -> Bool {
        let type = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        guard !type.isEmpty, !type.hasSuffix("]"), !type.hasPrefix("_"), !type.contains("interval"),
              !type.contains("point"), !type.contains("range"), type != "tinyint(1)", !type.contains("<"),
              !type.contains("|"), !["array(", "map(", "tuple(", "nested("].contains(where: type.hasPrefix) else { return false }
        return ["int", "serial", "numeric", "decimal", "real", "double", "float", "money", "counter", "number"]
            .contains { type.contains($0) }
    }

    /// Columns where at least one of the first `sampleLimit` rows has a value and every non-NULL value parses as a number.
    static func inferColumns(columnCount: Int, rows: [[CellValue]], sampleLimit: Int = 200) -> Set<Int> {
        var result = Set<Int>()
        let sample = rows.prefix(sampleLimit)
        for column in 0..<columnCount {
            var sawValue = false
            var allNumbers = true
            for row in sample {
                guard column < row.count, let value = row[column] else { continue }
                sawValue = true
                if QueryResultSorter.number(from: value) == nil {
                    allNumbers = false
                    break
                }
            }
            if sawValue && allNumbers { result.insert(column) }
        }
        return result
    }
}

/// Table column that remembers which entry of the grid's `columns` it shows, independent of on-screen order.
final class GridTableColumn: NSTableColumn {
    /// Index into the grid's `columns`; -1 for the row-number column.
    var dataIndex = -1
    var isRowNumber: Bool { dataIndex < 0 }

    init(dataIndex: Int, identifier: NSUserInterfaceItemIdentifier) {
        self.dataIndex = dataIndex
        super.init(identifier: identifier)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
}

/// NSTableView with grid keyboard handling and responder actions (copy:, delete:).
final class GridTableView: NSTableView {
    weak var grid: GridCoordinator?

    override func keyDown(with event: NSEvent) {
        if grid?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        grid?.copySelectedRows(includeHeader: false)
    }

    @objc func delete(_ sender: Any?) {
        grid?.deleteSelectedRows()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return numberOfSelectedRows > 0
        case #selector(delete(_:)):
            return numberOfSelectedRows > 0 && grid?.canDeleteRows == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// Row view that tints inserted / deleted rows on top of the alternating background.
final class GridRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("DbeeGridRow")

    var rowState: GridRowState = .normal {
        didSet { if rowState != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let tint: NSColor? = switch rowState {
        case .normal: nil
        case .inserted: GridMetrics.insertedRowColor
        case .deleted: GridMetrics.deletedRowColor
        }
        if let tint {
            tint.setFill()
            dirtyRect.fill(using: .sourceOver)
        }
    }
}

/// Cell label whose accessibility label ("column: value") is built only when assistive technology asks for it.
final class GridLabel: NSTextField {
    var columnName = ""

    override func accessibilityLabel() -> String? {
        "\(columnName): \(stringValue)"
    }
}

/// Data cell: a single-line label plus layer-drawn edit highlight and focus ring (no backing store needed).
final class GridCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("DbeeGridCell")

    private enum Style {
        case value, null, struckThrough, editing
    }

    let label: GridLabel
    private var style: Style = .value
    private var expansionToolTips = true

    var highlightColor: NSColor? {
        didSet { if highlightColor != oldValue { needsDisplay = true } }
    }

    var showsFocusRing = false {
        didSet { if showsFocusRing != oldValue { needsDisplay = true } }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if showsFocusRing { needsDisplay = true } }
    }

    init() {
        let height = GridMetrics.rowHeight
        label = GridLabel(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        identifier = Self.reuseID
        wantsLayer = true

        let textHeight = ceil(GridMetrics.font.ascender - GridMetrics.font.descender + GridMetrics.font.leading)
        label.frame = NSRect(
            x: GridMetrics.cellInset,
            y: floor((height - textHeight) / 2),
            width: 100 - GridMetrics.cellInset * 2,
            height: textHeight
        )
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        label.font = GridMetrics.font
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.allowsExpansionToolTips = true
        label.isEditable = false
        label.isSelectable = false
        label.focusRingType = .none
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = highlightColor?.cgColor
            if showsFocusRing {
                let color: NSColor = backgroundStyle == .emphasized
                    ? .alternateSelectedControlTextColor.withAlphaComponent(0.9)
                    : .keyboardFocusIndicatorColor
                layer.borderColor = color.cgColor
                layer.borderWidth = 1.5
                layer.cornerRadius = 3
            } else {
                layer.borderWidth = 0
                layer.cornerRadius = 0
            }
        }
    }

    /// Displays `value` for `column`. Deleted rows are struck through. Only properties that change are touched,
    /// since this runs for every cell scrolled into view. `alignment` stays in effect while editing.
    func show(_ value: CellValue, column: String, struckThrough: Bool, alignment: NSTextAlignment = .natural) {
        label.columnName = column
        if label.alignment != alignment { label.alignment = alignment }
        let display = value.map { GridText.display($0) }
        let text = display?.text ?? "NULL"

        if struckThrough {
            style = .struckThrough
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: value == nil ? GridMetrics.nullFont : GridMetrics.font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ])
        } else {
            let wanted: Style = value == nil ? .null : .value
            if style != wanted {
                style = wanted
                label.font = wanted == .null ? GridMetrics.nullFont : GridMetrics.font
                label.textColor = wanted == .null ? .secondaryLabelColor : .labelColor
            }
            label.stringValue = text
        }

        var toolTip: String?
        if let value, let display, display.isMultiline || display.isClipped, value.utf8.count <= GridText.tooltipLimit {
            toolTip = value
        }
        if toolTip != nil || label.toolTip != nil {
            label.toolTip = toolTip
        }
        setExpansionToolTips(toolTip == nil)
    }

    private func setExpansionToolTips(_ enabled: Bool) {
        guard enabled != expansionToolTips else { return }
        expansionToolTips = enabled
        label.allowsExpansionToolTips = enabled
    }

    /// Switches the label into an editable text field showing the raw value.
    func beginEditing(_ value: CellValue, delegate: NSTextFieldDelegate) {
        style = .editing
        label.toolTip = nil
        setExpansionToolTips(false)
        label.font = GridMetrics.font
        label.textColor = .labelColor
        label.stringValue = value ?? ""
        label.lineBreakMode = .byClipping
        label.cell?.isScrollable = true
        label.cell?.wraps = false
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.focusRingType = .exterior
        label.isEditable = true
        label.isSelectable = true
        label.delegate = delegate
    }

    func endEditing() {
        guard label.isEditable else { return }
        label.isEditable = false
        label.isSelectable = false
        label.delegate = nil
        label.drawsBackground = false
        label.focusRingType = .none
        label.cell?.isScrollable = false
        label.lineBreakMode = .byTruncatingTail
    }
}

/// Row-number gutter cell.
final class GridRowNumberView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("DbeeGridRowNumber")

    private let label = NSTextField(labelWithString: "")

    init() {
        let height = GridMetrics.rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: height))
        identifier = Self.reuseID
        let font = GridMetrics.rowNumberFont
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        label.frame = NSRect(x: 2, y: floor((height - textHeight) / 2), width: 40 - GridMetrics.rowNumberTrailingInset - 2, height: textHeight)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        label.font = font
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byClipping
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    func show(row: Int) {
        let text = String(row + 1)
        label.stringValue = text
        label.setAccessibilityLabel("Row \(text)")
    }
}
