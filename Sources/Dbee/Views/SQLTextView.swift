import AppKit
import SwiftUI

/// NSTextView-based SQL editor with syntax highlighting, line numbers and completion.
///
/// Uses an explicit TextKit 1 stack (NSLayoutManager) so colouring can be applied as layout-manager
/// temporary attributes: they never touch the text storage, so they don't affect undo, and only the
/// visible part of the document is coloured (re-applied while scrolling).
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    var kind: DatabaseKind
    var fontSize: CGFloat
    /// Table and column names offered by completion in addition to keywords.
    var completionWords: [String] = []
    /// Range to underline as an error.
    var errorRange: NSRange? = nil
    /// Reports the selected range (UTF-16) so the caller can run the selection or the statement at the cursor.
    @Binding var selectedRange: NSRange
    /// Called with `false` for ⌘↩ (run selection / statement) and `true` for ⇧⌘↩ (run all) while the editor
    /// has focus, and from the editor's context menu. nil hides the Run menu items.
    var onRun: ((_ runAll: Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
}

// MARK: - Coordinator

extension SQLTextView {
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Documents up to this many UTF-16 units are re-tokenised synchronously on every edit;
        /// larger ones are tokenised off the main thread after a short pause in typing.
        static let synchronousHighlightLimit = 200_000

        private(set) var parent: SQLTextView
        private var textView: SQLEditorTextView?
        private var ruler: SQLLineNumberRulerView?

        private var kind: DatabaseKind
        private var fontSize: CGFloat = 0
        /// The text last pushed to / received from the binding (same storage, so comparisons are cheap).
        private var lastText = ""
        private var isApplyingBinding = false
        private var incomingErrorRange: NSRange?
        private var showsErrorMarker = false

        private var tokens: [SQLHighlighter.Token] = []
        /// Character range coloured since the tokens last changed; scrolling inside it needs no work.
        private var colouredRange = NSRange(location: NSNotFound, length: 0)
        private var textVersion = 0
        private var highlightTask: Task<Void, Never>?
        private var pendingEdit: (range: NSRange, delta: Int)?
        /// Per-editor undo stack, so undo never targets a text view that was torn down with its tab.
        private let undoManager = UndoManager()

        init(_ parent: SQLTextView) {
            self.parent = parent
            self.kind = parent.kind
        }

        // MARK: Setup

        func makeScrollView() -> NSScrollView {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            layoutManager.allowsNonContiguousLayout = true
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)

            let textView = SQLEditorTextView(frame: .zero, textContainer: container)
            textView.configureForSQL()
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            textView.kind = parent.kind
            textView.completionWords = parent.completionWords
            textView.runHandler = parent.onRun
            textView.isInsideLiteral = { [weak self] location in self?.isInsideLiteral(location) ?? false }
            textView.delegate = self

            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.documentView = textView

            let ruler = SQLLineNumberRulerView(textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.hasHorizontalRuler = false
            scrollView.rulersVisible = true

            self.textView = textView
            self.ruler = ruler

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clipView)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportDidChange(_:)),
                                                   name: NSView.frameDidChangeNotification, object: clipView)

            applyFont(size: parent.fontSize)
            storage.setAttributedString(NSAttributedString(string: parent.text, attributes: textView.typingAttributes))
            lastText = parent.text
            retokenize()

            let length = storage.length
            let initial = parent.selectedRange
            if initial.location != NSNotFound, NSMaxRange(initial) <= length {
                textView.setSelectedRange(initial)
            } else {
                textView.setSelectedRange(NSRange(location: length, length: 0))
            }
            incomingErrorRange = parent.errorRange
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
                self.showError(self.incomingErrorRange, scroll: false)
            }
            return scrollView
        }

        func update(with view: SQLTextView) {
            parent = view
            guard let textView else { return }
            textView.completionWords = view.completionWords
            textView.runHandler = view.onRun
            if view.fontSize != fontSize {
                applyFont(size: view.fontSize)
            }
            if view.kind != kind {
                kind = view.kind
                textView.kind = view.kind
                retokenize()
            }
            if view.text != lastText {
                replaceText(with: view.text)
            }
            if view.errorRange != incomingErrorRange {
                incomingErrorRange = view.errorRange
                showError(view.errorRange, scroll: true)
            }
        }

        func tearDown() {
            undoManager.removeAllActions()
            highlightTask?.cancel()
            textView?.cancelAutoCompletion()
            NotificationCenter.default.removeObserver(self)
        }

        private func applyFont(size: CGFloat) {
            guard let textView else { return }
            fontSize = size
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph,
            ]
            textView.font = font
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = attributes
            if let storage = textView.textStorage, storage.length > 0 {
                storage.beginEditing()
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
                storage.endEditing()
            }
            ruler?.textFont = font
        }

        /// Replaces the whole text with a value that came from the binding (e.g. "Replace Editor Text"
        /// in History). Undoable, and keeps the binding from echoing the change back.
        private func replaceText(with newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            isApplyingBinding = true
            defer { isApplyingBinding = false }
            lastText = newText
            if textView.shouldChangeText(in: full, replacementString: newText) {
                storage.replaceCharacters(in: full, with: NSAttributedString(string: newText, attributes: textView.typingAttributes))
                textView.didChangeText()
            } else {
                storage.setAttributedString(NSAttributedString(string: newText, attributes: textView.typingAttributes))
                textChanged()
            }
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString {
                pendingEdit = (affectedCharRange, (replacementString as NSString).length - affectedCharRange.length)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            textChanged()
            guard !isApplyingBinding, let textView else { return }
            let text = textView.string
            lastText = text
            parent.text = text
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                let range = textView.selectedRange()
                if self.parent.selectedRange != range { self.parent.selectedRange = range }
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let storage = textView.textStorage, NSMaxRange(charRange) <= storage.length else { return [] }
            let partial = storage.mutableString.substring(with: charRange)
            index?.pointee = 0
            return SQLCompletion.candidates(for: partial, words: parent.completionWords, kind: kind)
        }

        // MARK: Highlighting

        private func textChanged() {
            textVersion += 1
            clearErrorMarker()
            ruler?.invalidateLineStarts()
            guard let storage = textView?.textStorage else { return }
            if storage.length <= Self.synchronousHighlightLimit {
                pendingEdit = nil
                retokenize()
            } else {
                shiftTokensForPendingEdit()
                scheduleBackgroundTokenize()
            }
        }

        private func retokenize() {
            highlightTask?.cancel()
            guard let storage = textView?.textStorage else { return }
            if storage.length <= Self.synchronousHighlightLimit {
                tokens = SQLHighlighter.tokens(in: storage.mutableString, kind: kind)
                recolour()
            } else {
                scheduleBackgroundTokenize()
            }
        }

        private func scheduleBackgroundTokenize() {
            highlightTask?.cancel()
            let version = textVersion
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let snapshot = textView.string as NSString
                let kind = self.kind
                let tokens = await Task.detached(priority: .userInitiated) {
                    SQLHighlighter.tokens(in: snapshot, kind: kind)
                }.value
                guard !Task.isCancelled, self.textVersion == version else { return }
                self.tokens = tokens
                self.recolour()
            }
        }

        /// Keeps colours roughly aligned while a large document waits to be re-tokenised.
        private func shiftTokensForPendingEdit() {
            guard let edit = pendingEdit else { return }
            pendingEdit = nil
            let editStart = edit.range.location
            let editEnd = NSMaxRange(edit.range)
            tokens = tokens.compactMap { token in
                if NSMaxRange(token.range) <= editStart { return token }
                guard token.range.location >= editEnd else { return nil }
                var shifted = token
                shifted.range.location += edit.delta
                return shifted
            }
            recolour()
        }

        private func recolour() {
            colouredRange = NSRange(location: NSNotFound, length: 0)
            colourVisibleText()
        }

        /// Applies token colours to the visible text plus one screen above and below.
        private func colourVisibleText() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let storage = textView.textStorage else { return }
            let length = storage.length
            guard length > 0 else { return }
            let visible = textView.visibleRect
            guard visible.height > 0 else { return }
            let area = NSRect(x: 0, y: visible.minY - visible.height, width: max(textView.bounds.width, visible.maxX),
                              height: visible.height * 3)
            let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: container)
            let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard chars.length > 0 else { return }
            if colouredRange.location != NSNotFound, NSIntersectionRange(chars, colouredRange) == chars { return }

            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: chars)
            let end = NSMaxRange(chars)
            let documentRange = NSRange(location: 0, length: length)
            var index = SQLHighlighter.firstTokenIndex(endingAfter: chars.location, in: tokens)
            while index < tokens.count {
                let token = tokens[index]
                if token.range.location >= end { break }
                index += 1
                guard let colour = token.kind.editorColor else { continue }
                let range = NSIntersectionRange(token.range, documentRange)
                if range.length > 0 {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: colour, forCharacterRange: range)
                }
            }
            colouredRange = chars
        }

        @objc private func viewportDidChange(_ notification: Notification) {
            if let textView, let scrollView = textView.enclosingScrollView {
                let size = scrollView.contentSize
                if textView.minSize != size { textView.minSize = size }
            }
            colourVisibleText()
            ruler?.needsDisplay = true
        }

        private func isInsideLiteral(_ location: Int) -> Bool {
            let index = SQLHighlighter.firstTokenIndex(endingAfter: location - 1, in: tokens)
            guard index < tokens.count else { return false }
            let token = tokens[index]
            guard token.kind == .string || token.kind == .comment else { return false }
            return token.range.location < location && location <= NSMaxRange(token.range)
        }

        // MARK: Error marker

        private func showError(_ range: NSRange?, scroll: Bool) {
            clearErrorMarker()
            guard let range, range.location != NSNotFound, let textView, let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            guard clamped.length > 0 else { return }
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: NSColor.systemRed,
                .backgroundColor: NSColor.systemRed.withAlphaComponent(0.12),
            ], forCharacterRange: clamped)
            showsErrorMarker = true
            if scroll { textView.scrollRangeToVisible(NSRange(location: clamped.location, length: 0)) }
        }

        private func clearErrorMarker() {
            guard showsErrorMarker, let textView, let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            showsErrorMarker = false
            let full = NSRange(location: 0, length: storage.length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        }
    }
}

private extension SQLHighlighter.TokenKind {
    /// Adaptive system colours (resolved at draw time, so Dark Mode and accessibility contrast just work).
    /// nil means the default text colour.
    var editorColor: NSColor? {
        switch self {
        case .keyword: .systemPurple
        case .type: .systemIndigo
        case .function: .systemTeal
        case .string: .systemRed
        case .number: .systemBlue
        case .comment: .secondaryLabelColor
        case .parameter: .systemOrange
        case .quotedIdentifier: nil
        }
    }
}

// MARK: - Text view

/// The editor's NSTextView: SQL-safe defaults (no substitutions, checking, Writing Tools or Services),
/// auto-indent, soft tabs, ⌘/ comment toggling, run shortcuts and unobtrusive auto-completion.
final class SQLEditorTextView: NSTextView {
    static let indentWidth = 2

    var kind: DatabaseKind = .postgres
    var completionWords: [String] = []
    var runHandler: ((Bool) -> Void)?
    /// Whether a UTF-16 offset sits inside a string literal or comment (no auto-completion there).
    var isInsideLiteral: ((Int) -> Bool)?

    private var autoCompletionTask: Task<Void, Never>?

    func configureForSQL() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        enabledTextCheckingTypes = 0
        displaysLinkToolTips = false
        allowsDocumentBackgroundColorChange = false
        allowsCharacterPickerTouchBarItem = false
        inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
            mathExpressionCompletionType = .no
        }
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        textContainerInset = NSSize(width: 2, height: 6)
        setAccessibilityLabel("SQL Editor")
    }

    private var text: NSMutableString? { textStorage?.mutableString }

    // MARK: Privacy

    /// No Services: the editor's contents are never handed to other apps.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

    /// No force-click Look Up.
    override func quickLook(with event: NSEvent) {}

    // MARK: Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(self)
            }
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, let runHandler {
            if flags == .command { runHandler(false); return true }
            if flags == [.command, .shift] { runHandler(true); return true }
        }
        guard flags == .command || flags == [.command, .shift] || flags == [.command, .option] else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.charactersIgnoringModifiers ?? "").lowercased() {
        case "/" where flags == .command:
            toggleComment(nil)
        case "]" where flags == .command:
            shiftRight(nil)
        case "[" where flags == .command:
            shiftLeft(nil)
        case "f" where flags == .command:
            performFinderAction(.showFindInterface)
        case "f" where flags == [.command, .option]:
            performFinderAction(.showReplaceInterface)
        case "g" where flags == .command:
            performFinderAction(.nextMatch)
        case "g" where flags == [.command, .shift]:
            performFinderAction(.previousMatch)
        case "e" where flags == .command:
            performFinderAction(.setSearchString)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Escape shows completions (NSTextView's default); ⌘. is left to the Stop command.
    override func cancelOperation(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command) { return }
        super.cancelOperation(sender)
    }

    private func performFinderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    // MARK: Editing helpers

    override func insertNewline(_ sender: Any?) {
        guard let text else { return super.insertNewline(sender) }
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = lineStart
        while end < selection.location, Self.isIndentCharacter(text.character(at: end)) { end += 1 }
        let indent = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
        insertText("\n" + indent, replacementRange: selection)
    }

    override func insertTab(_ sender: Any?) {
        guard let text else { return super.insertTab(sender) }
        let selection = selectedRange()
        if selection.length > 0, text.substring(with: selection).contains(where: \.isNewline) {
            shiftRight(sender)
            return
        }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        let count = Self.indentWidth - column % Self.indentWidth
        insertText(String(repeating: " ", count: count), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLeft(sender)
    }

    @objc func toggleComment(_ sender: Any?) {
        transformSelectedLines(actionName: "Toggle Comment", SQLEditing.toggleLineComments)
    }

    @objc func shiftRight(_ sender: Any?) {
        transformSelectedLines(actionName: "Shift Right") { SQLEditing.indent($0, width: Self.indentWidth) }
    }

    @objc func shiftLeft(_ sender: Any?) {
        transformSelectedLines(actionName: "Shift Left") { SQLEditing.outdent($0, width: Self.indentWidth) }
    }

    /// Rewrites the lines touched by the selection as one undoable change.
    private func transformSelectedLines(actionName: String, _ transform: (String) -> String) {
        guard let storage = textStorage, isEditable else { return }
        let text = storage.mutableString
        let selection = selectedRange()
        var probe = selection
        if probe.length > 0, Self.isLineBreak(text.character(at: NSMaxRange(probe) - 1)) { probe.length -= 1 }
        let block = text.lineRange(for: probe)
        let original = text.substring(with: block)
        let replaced = transform(original)
        guard replaced != original else { return }

        breakUndoCoalescing()
        guard shouldChangeText(in: block, replacementString: replaced) else { return }
        storage.replaceCharacters(in: block, with: NSAttributedString(string: replaced, attributes: typingAttributes))
        didChangeText()
        undoManager?.setActionName(actionName)

        let newLength = (replaced as NSString).length
        let trailingBreak = replaced.hasSuffix("\n") ? 1 : 0
        let blockEnd = block.location + newLength - trailingBreak
        if selection.length == 0 {
            let caret = selection.location + newLength - block.length
            setSelectedRange(NSRange(location: min(max(caret, block.location), blockEnd), length: 0))
        } else {
            setSelectedRange(NSRange(location: block.location, length: blockEnd - block.location))
        }
    }

    private static func isIndentCharacter(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    // MARK: Completion

    override var rangeForUserCompletion: NSRange {
        let selection = selectedRange()
        guard selection.length == 0, let text else { return NSRange(location: NSNotFound, length: 0) }
        var start = selection.location
        while start > 0, SQLHighlighter.isIdentifierPart(text.character(at: start - 1)) { start -= 1 }
        // Nothing typed yet: complete from an empty prefix (schema objects only).
        if start == selection.location { return selection }
        guard SQLHighlighter.isIdentifierStart(text.character(at: start)) else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: start, length: selection.location - start)
    }

    /// Candidates are never previewed inline; text changes only when the user accepts one with
    /// Return, Tab or a click.
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard flag else { return }
        let accepted: Bool
        switch movement {
        case NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue:
            accepted = true
        case NSTextMovement.other.rawValue:
            let type = NSApp.currentEvent?.type
            accepted = type == .leftMouseDown || type == .leftMouseUp
        default:
            accepted = false
        }
        guard accepted, let length = textStorage?.length, NSMaxRange(charRange) <= length else { return }
        insertText(word, replacementRange: charRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let units = typed.utf16
        if units.count == 1, let unit = units.first, SQLHighlighter.isIdentifierPart(unit), !hasMarkedText() {
            scheduleAutoCompletion()
        } else {
            cancelAutoCompletion()
        }
    }

    func cancelAutoCompletion() {
        autoCompletionTask?.cancel()
        autoCompletionTask = nil
    }

    private func scheduleAutoCompletion() {
        autoCompletionTask?.cancel()
        let caret = selectedRange()
        autoCompletionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.autoCompleteIfUseful(expectedCaret: caret)
        }
    }

    private func autoCompleteIfUseful(expectedCaret: NSRange) {
        guard let window, window.isKeyWindow, window.firstResponder === self, let text,
              selectedRange() == expectedCaret, expectedCaret.length == 0, !hasMarkedText() else { return }
        let range = rangeForUserCompletion
        guard range.location != NSNotFound, range.length >= 2, NSMaxRange(range) == expectedCaret.location else { return }
        if expectedCaret.location < text.length, SQLHighlighter.isIdentifierPart(text.character(at: expectedCaret.location)) { return }
        if isInsideLiteral?(expectedCaret.location) == true { return }
        var index = 0
        guard let candidates = completions(forPartialWordRange: range, indexOfSelectedItem: &index), !candidates.isEmpty else { return }
        complete(nil)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        if runHandler != nil {
            let hasSelection = selectedRange().length > 0
            menu.addItem(makeItem(hasSelection ? "Run Selection" : "Run Statement", #selector(runFromMenu(_:)), "\r"))
            menu.addItem(makeItem("Run All", #selector(runAllFromMenu(_:)), "\r", [.command, .shift]))
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Cut", #selector(cut(_:)), "x"))
        menu.addItem(makeItem("Copy", #selector(copy(_:)), "c"))
        menu.addItem(makeItem("Paste", #selector(paste(_:)), "v"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Select All", #selector(selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Toggle Comment", #selector(toggleComment(_:)), "/"))
        menu.addItem(makeItem("Shift Right", #selector(shiftRight(_:)), "]"))
        menu.addItem(makeItem("Shift Left", #selector(shiftLeft(_:)), "["))
        menu.addItem(.separator())
        let find = makeItem("Find…", #selector(performTextFinderAction(_:)), "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(find)
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String,
                          _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func runFromMenu(_ sender: Any?) { runHandler?(false) }
    @objc private func runAllFromMenu(_ sender: Any?) { runHandler?(true) }
}

// MARK: - Line-oriented edits

/// Pure text transforms behind ⌘/, Tab / ⇧Tab and ⌘] / ⌘[. Each takes and returns whole lines.
enum SQLEditing {
    /// Comments every non-blank line with "-- " at the block's smallest indentation, or strips the
    /// markers when every non-blank line is already a line comment.
    static func toggleLineComments(_ block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        let hasTrailingBreak = block.hasSuffix("\n")
        let editable = hasTrailingBreak ? lines.indices.dropLast() : lines.indices.dropLast(0)
        let content = editable.filter { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !content.isEmpty else {
            guard let first = editable.first else { return block }
            let indent = lines[first].prefix(while: isIndent)
            lines[first] = String(indent) + "-- " + String(lines[first].dropFirst(indent.count))
            return lines.joined(separator: "\n")
        }

        let allCommented = content.allSatisfy { lines[$0].drop(while: isIndent).hasPrefix("--") }
        if allCommented {
            for i in content {
                let line = lines[i]
                let indent = line.prefix(while: isIndent)
                var rest = line.dropFirst(indent.count).dropFirst(2)
                if rest.first == " " { rest = rest.dropFirst() }
                lines[i] = String(indent) + String(rest)
            }
        } else {
            let column = content.map { lines[$0].prefix(while: isIndent).count }.min() ?? 0
            for i in content {
                let line = lines[i]
                lines[i] = String(line.prefix(column)) + "-- " + String(line.dropFirst(column))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Adds `width` spaces in front of every non-blank line.
    static func indent(_ block: String, width: Int) -> String {
        let pad = String(repeating: " ", count: width)
        return block.components(separatedBy: "\n").map { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : pad + line
        }.joined(separator: "\n")
    }

    /// Removes up to `width` leading spaces (or one leading tab) from every line.
    static func outdent(_ block: String, width: Int) -> String {
        block.components(separatedBy: "\n").map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(while: { $0 == " " }).count
            return String(line.dropFirst(min(spaces, width)))
        }.joined(separator: "\n")
    }

    private static func isIndent(_ c: Character) -> Bool { c == " " || c == "\t" }
}

// MARK: - Line numbers

/// Gutter drawing line numbers for the visible part of a TextKit 1 NSTextView. Line starts are cached and
/// binary-searched, so drawing cost depends on the number of visible lines, not the document size.
final class SQLLineNumberRulerView: NSRulerView {
    var textFont: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) {
        didSet {
            labelFont = .monospacedDigitSystemFont(ofSize: max(9, textFont.pointSize * 0.85), weight: .regular)
            updateThickness()
            needsDisplay = true
        }
    }

    private weak var textView: NSTextView?
    private var labelFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 36
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func invalidateLineStarts() {
        lineStartsValid = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return }
        if !lineStartsValid { recountLines() }

        let length = storage.length
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = lineIndex(containing: textView.selectedRange().location)
        let baseline = layoutManager.defaultBaselineOffset(for: textView.font ?? textFont)
        let originY = textView.textContainerOrigin.y
        let rightEdge = bounds.width - 6

        let normal: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]

        var line = lineIndex(containing: chars.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.height == 0 && length > 0 { break }
            } else {
                if start > NSMaxRange(chars) { break }
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let top = fragment.minY + originY
            if top > visible.maxY { break }
            let y = convert(NSPoint(x: 0, y: top), from: textView).y
            let label = String(line + 1) as NSString
            let attributes = line == currentLine ? current : normal
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: rightEdge - width, y: y + baseline - labelFont.ascender), withAttributes: attributes)
            line += 1
        }
    }

    /// Clicking a line number selects that line.
    override func mouseDown(with event: NSEvent) {
        guard let textView, let storage = textView.textStorage else { return }
        if !lineStartsValid { recountLines() }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let location = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: container)
        let char = min(layoutManager.characterIndexForGlyph(at: glyph), storage.length)
        let lineRange = storage.mutableString.lineRange(for: NSRange(location: char, length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(lineRange)
    }

    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func recountLines() {
        lineStartsValid = true
        guard let text = textView?.textStorage?.mutableString else {
            lineStarts = [0]
            return
        }
        let length = text.length
        var starts = [0]
        starts.reserveCapacity(max(lineStarts.count, 16))
        let chunkSize = 16_384
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var location = 0
        var previousWasCR = false
        while location < length {
            let count = min(chunkSize, length - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: count))
            }
            for k in 0..<count {
                let c = buffer[k]
                if c == 0x0A {
                    if previousWasCR { starts[starts.count - 1] = location + k + 1 } else { starts.append(location + k + 1) }
                } else if c == 0x0D || c == 0x2028 || c == 0x2029 {
                    starts.append(location + k + 1)
                }
                previousWasCR = c == 0x0D
            }
            location += count
        }
        lineStarts = starts
        updateThickness()
    }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: labelFont]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 16)
        guard abs(ruleThickness - thickness) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ruleThickness = thickness
            self.scrollView?.tile()
        }
    }
}
