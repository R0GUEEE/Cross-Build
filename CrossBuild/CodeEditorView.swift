import SwiftUI
import UIKit

struct CodeEditorOptions {
    var fontSize: CGFloat
    var tabWidth: Int
    var insertSpaces: Bool
    var wordWrap: Bool
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    var showInvisibleCharacters: Bool
    var autoClosePairs: Bool
}

struct CodeEditorSelection: Equatable {
    var line: Int = 1
    var column: Int = 1
    var selectedLength: Int = 0
    /// The actual caret/selection range in the document, in UTF-16 units. The
    /// editing commands that act on a *selection* (sorting, for one) need the
    /// range itself -- line/column alone can only describe a caret, which is why
    /// "Sort Selected Lines" used to fall back to sorting the whole file.
    var range: NSRange = NSRange(location: 0, length: 0)
}

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: CodeEditorSelection
    let fileName: String
    let options: CodeEditorOptions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> CodeEditorContainer {
        let view = CodeEditorContainer()
        view.textView.delegate = context.coordinator
        view.textView.text = text
        view.apply(options: options)
        context.coordinator.container = view
        context.coordinator.highlight(text: text, fileName: fileName)
        return view
    }

    func updateUIView(_ uiView: CodeEditorContainer, context: Context) {
        context.coordinator.parent = self
        uiView.apply(options: options)
        if uiView.textView.text != text {
            let selected = uiView.textView.selectedRange
            uiView.textView.text = text
            uiView.textView.selectedRange = NSRange(location: min(selected.location, text.utf16.count), length: 0)
            context.coordinator.highlight(text: text, fileName: fileName)
        }
        // The text view reports selection changes upward but never accepts them,
        // so a caret set from outside -- Go to Line, Find Next -- has to be pushed
        // in. After a tap the two already agree, so this is a no-op then.
        let target = selection.range
        if target.location != NSNotFound,
           target.location + target.length <= uiView.textView.text.utf16.count,
           target.location != uiView.textView.selectedRange.location
            || target.length != uiView.textView.selectedRange.length {
            uiView.textView.selectedRange = target
            uiView.textView.scrollRangeToVisible(target)
        }
        uiView.updateGutter()
        uiView.updateCurrentLine()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var container: CodeEditorContainer?
        private var applyingAttributes = false

        init(parent: CodeEditorView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !applyingAttributes else { return }
            parent.text = textView.text
            container?.updateGutter()
            container?.updateCurrentLine()
            updateSelection(textView)
            scheduleHighlight(text: textView.text, fileName: parent.fileName)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateSelection(textView)
            container?.updateCurrentLine()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // A newline carries the current line's indentation. Without it every
            // line in a block drifts back to column 0 and has to be re-indented
            // by hand, which is the single most-typed correction in a code editor.
            if replacement == "\n" {
                let ns = textView.text as NSString
                let caret = min(range.location, ns.length)
                let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
                let indent = String(ns.substring(from: lineStart).prefix { $0 == " " || $0 == "\t" })
                guard !indent.isEmpty else { return true }
                let insertion = "\n" + indent
                if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                   let end = textView.position(from: start, offset: range.length),
                   let textRange = textView.textRange(from: start, to: end) {
                    textView.replace(textRange, withText: insertion)
                    if let caretPosition = textView.position(from: start, offset: (insertion as NSString).length) {
                        textView.selectedTextRange = textView.textRange(from: caretPosition, to: caretPosition)
                    }
                    return false
                }
            }
            if replacement == "\t" {
                let unit = parent.options.insertSpaces ? String(repeating: " ", count: max(1, parent.options.tabWidth)) : "\t"
                textView.replace(textView.selectedTextRange ?? UITextRange(), withText: unit)
                return false
            }
            guard parent.options.autoClosePairs, replacement.count == 1,
                  let pair = ["{":"}", "[":"]", "(" : ")", "\"":"\"", "'":"'"][replacement] else { return true }
            if let swiftRange = Range(range, in: textView.text) {
                let next = textView.text[swiftRange.upperBound...].first
                if next == Character(pair) { return true }
            }
            let insertion = replacement + pair
            if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
               let end = textView.position(from: start, offset: range.length),
               let r = textView.textRange(from: start, to: end) {
                textView.replace(r, withText: insertion)
                if let caret = textView.position(from: start, offset: 1) {
                    textView.selectedTextRange = textView.textRange(from: caret, to: caret)
                }
                return false
            }
            return true
        }

        private func updateSelection(_ textView: UITextView) {
            let ns = textView.text as NSString
            let location = min(textView.selectedRange.location, ns.length)
            let prefix = ns.substring(to: location)
            let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lastBreak = prefix.lastIndex(of: "\n")
            let column = lastBreak.map { prefix.distance(from: $0, to: prefix.endIndex) } ?? prefix.count + 1
            let value = CodeEditorSelection(line: line, column: column,
                                            selectedLength: textView.selectedRange.length,
                                            range: textView.selectedRange)
            if parent.selection != value { parent.selection = value }
        }

        /// Re-highlighting the whole document on every keystroke is
        /// O(document size x 5 regular expressions) per character typed, and
        /// reassigning `attributedText` that often also resets the text view's
        /// typing attributes. Coalesce instead: the highlight runs once the user
        /// pauses, taking the text as it is then.
        private var highlightWorkItem: DispatchWorkItem?

        private static let highlightDebounce: TimeInterval = 0.15

        func scheduleHighlight(text: String, fileName: String) {
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.highlight(text: text, fileName: fileName)
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDebounce, execute: item)
        }

        func highlight(text: String, fileName: String) {
            guard let textView = container?.textView else { return }
            // A debounced highlight can outlive its text; never paint attributes
            // computed for a previous revision onto the current document. The
            // file name matters as much as the text: it selects the language, so
            // a stale name paints the wrong grammar whenever the queued text
            // happens to match the document now on screen -- which is exactly
            // what two empty files, or a file switch inside the debounce window,
            // looks like.
            guard textView.text == text, parent.fileName == fileName else { return }
            let selected = textView.selectedRange
            let baseFont = UIFont.monospacedSystemFont(ofSize: parent.options.fontSize, weight: .regular)
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: UIColor.label
            ])
            let language = EditorLanguage(fileName: fileName)
            apply(pattern: language.commentPattern, color: .systemGray, to: attributed)
            apply(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemRed, to: attributed)
            apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: .systemOrange, to: attributed)
            apply(pattern: language.keywordPattern, color: .systemPurple, to: attributed)
            apply(pattern: language.typePattern, color: .systemTeal, to: attributed)
            // The two things that make a text view read as a code editor: where
            // else the name under the caret is used, and which bracket closes the
            // one beside it.
            highlightOccurrences(of: wordAtCaret(in: textView), in: attributed)
            highlightMatchingBracket(in: attributed)
            if language == .logos {
                apply(pattern: #"%\w+"#, color: .systemBlue, to: attributed)
            }
            if parent.options.showInvisibleCharacters {
                shadeWhitespace(in: attributed)
            }
            applyingAttributes = true
            textView.attributedText = attributed
            textView.selectedRange = NSRange(location: min(selected.location, attributed.length), length: min(selected.length, max(0, attributed.length - min(selected.location, attributed.length))))
            applyingAttributes = false
        }

        /// Makes spaces and tabs visible without altering the text: a run of
        /// whitespace gets a subtle background, which is exactly what the
        /// "Show invisible characters" option promises. Done by attribute rather
        /// than by substituting glyphs so the document on disk is untouched.
        private func shadeWhitespace(in text: NSMutableAttributedString) {
            guard let regex = try? NSRegularExpression(pattern: #"[ \t]+"#) else { return }
            regex.enumerateMatches(in: text.string, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                guard let range = match?.range else { return }
                text.addAttribute(.backgroundColor, value: UIColor.systemFill, range: range)
            }
        }

        /// The identifier the caret sits in or next to, if any.
        private func wordAtCaret(in textView: UITextView) -> String? {
            let text = textView.text as NSString
            guard text.length > 0 else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            let caret = min(max(0, textView.selectedRange.location), text.length)
            var start = caret
            while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), allowed.contains(scalar) {
                start -= 1
            }
            var end = caret
            while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), allowed.contains(scalar) {
                end += 1
            }
            guard end > start else { return nil }
            return text.substring(with: NSRange(location: start, length: end - start))
        }

        /// A subtle background on every other place the caret's word appears --
        /// the fastest way to see where else a name is used, and the reason an
        /// editor feels like it understands the code rather than just colouring it.
        private func highlightOccurrences(of word: String?, in text: NSMutableAttributedString) {
            guard let word, word.count > 1 else { return }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            regex.enumerateMatches(in: text.string, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                guard let range = match?.range else { return }
                text.addAttribute(.backgroundColor,
                                  value: UIColor.systemYellow.withAlphaComponent(0.18),
                                  range: range)
            }
        }

        /// Highlights the pair around the caret. Only the two brackets are marked;
        /// an unmatched one is left alone rather than guessed at.
        private func highlightMatchingBracket(in text: NSMutableAttributedString) {
            guard let textView = container?.textView else { return }
            let text = textView.text as NSString
            guard text.length > 0 else { return }

            let opens = Array("([{".utf16)
            let closes = Array(")]}".utf16)
            let caret = min(max(0, textView.selectedRange.location), text.length)

            // The bracket just before the caret, else the one under it.
            var candidates: [Int] = []
            if caret > 0 { candidates.append(caret - 1) }
            if caret < text.length { candidates.append(caret) }

            for index in candidates {
                let character = text.character(at: index)
                let isOpen = opens.firstIndex(of: character)
                let isClose = closes.firstIndex(of: character)
                guard let side = isOpen ?? isClose else { continue }
                let opening = isOpen != nil
                let target = opening ? closes[side] : opens[side]
                let step = opening ? 1 : -1
                var depth = 0
                var cursor = index
                while cursor >= 0, cursor < text.length {
                    let current = text.character(at: cursor)
                    if current == character {
                        depth += 1
                    } else if current == target {
                        depth -= 1
                        if depth == 0 {
                            let attributes: [NSAttributedString.Key: Any] = [
                                .backgroundColor: UIColor.systemBlue.withAlphaComponent(0.25),
                                .foregroundColor: UIColor.label
                            ]
                            text.addAttributes(attributes, range: NSRange(location: index, length: 1))
                            text.addAttributes(attributes, range: NSRange(location: cursor, length: 1))
                            return
                        }
                    }
                    cursor += step
                }
                return
            }
        }

        private func apply(pattern: String, color: UIColor, to text: NSMutableAttributedString) {
            guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            regex.enumerateMatches(in: text.string, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                guard let range = match?.range else { return }
                text.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }
}

final class CodeEditorContainer: UIView {
    let gutter = UILabel()
    let textView = UITextView()
    private let currentLine = UIView()
    private var options = CodeEditorOptions(fontSize: 15, tabWidth: 4, insertSpaces: true, wordWrap: true, showLineNumbers: true, highlightCurrentLine: true, showInvisibleCharacters: false, autoClosePairs: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        currentLine.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.35)
        currentLine.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.addSubview(currentLine)
        gutter.numberOfLines = 0
        gutter.textAlignment = .right
        gutter.textColor = .tertiaryLabel
        gutter.backgroundColor = .secondarySystemBackground
        gutter.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(gutter)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth: CGFloat = options.showLineNumbers ? max(42, gutter.intrinsicContentSize.width + 14) : 0
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
        updateCurrentLine()
    }

    func apply(options: CodeEditorOptions) {
        self.options = options
        let font = UIFont.monospacedSystemFont(ofSize: options.fontSize, weight: .regular)
        textView.font = font
        gutter.font = font
        gutter.isHidden = !options.showLineNumbers
        textView.textContainer.widthTracksTextView = options.wordWrap
        textView.textContainer.lineBreakMode = options.wordWrap ? .byWordWrapping : .byClipping
        textView.textContainer.maximumNumberOfLines = 0
        setNeedsLayout()
        updateGutter()
        updateCurrentLine()
    }

    func updateGutter() {
        let count = max(1, textView.text.components(separatedBy: "\n").count)
        gutter.text = (1...count).map(String.init).joined(separator: "\n")
        gutter.sizeToFit()
        setNeedsLayout()
    }

    func updateCurrentLine() {
        guard options.highlightCurrentLine, let selected = textView.selectedTextRange else {
            currentLine.isHidden = true
            return
        }
        currentLine.isHidden = false
        let caret = textView.caretRect(for: selected.start)
        currentLine.frame = CGRect(x: 0, y: caret.minY, width: textView.bounds.width, height: max(caret.height, textView.font?.lineHeight ?? 18))
        textView.sendSubviewToBack(currentLine)
    }
}

/// Shared rather than file-private: the edit commands need the language too, so
/// that "Toggle Comment" writes the marker this language actually uses.
enum EditorLanguage: Equatable {
    case swift, objc, cpp, c, logos, rust, go, zig, python, javascript, typescript, java, kotlin, shell, json, yaml, generic

    /// The marker a line comment starts with, or "" when there is none.
    var lineComment: String {
        switch self {
        case .python, .shell, .yaml: return "#"
        case .json, .generic: return ""
        default: return "//"
        }
    }

    /// For the editor status bar, which used to show a bare file extension.
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .objc: return "Objective-C"
        case .cpp: return "C++"
        case .c: return "C"
        case .logos: return "Logos"
        case .rust: return "Rust"
        case .go: return "Go"
        case .zig: return "Zig"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .shell: return "Shell"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .generic: return "Plain Text"
        }
    }

    init(fileName: String) {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "swift": self = .swift
        case "m": self = .objc
        case "mm": self = .cpp
        case "cpp","cc","cxx","hpp": self = .cpp
        case "c","h": self = .c
        case "xm","x": self = .logos
        case "rs": self = .rust
        case "go": self = .go
        case "zig": self = .zig
        case "py": self = .python
        case "js","jsx": self = .javascript
        case "ts","tsx": self = .typescript
        case "java": self = .java
        case "kt","kts": self = .kotlin
        case "sh","bash","zsh": self = .shell
        case "json": self = .json
        case "yml","yaml": self = .yaml
        default: self = .generic
        }
    }

    var commentPattern: String {
        switch self {
        case .python, .shell, .yaml: return #"(?m)#.*$"#
        case .json: return ""
        default: return #"(?m)//.*$|/\*[\s\S]*?\*/"#
        }
    }

    var keywordPattern: String {
        let words: String
        switch self {
        case .swift: words = "actor|as|associatedtype|async|await|break|case|catch|class|continue|default|defer|deinit|do|else|enum|extension|fallthrough|false|fileprivate|for|func|guard|if|import|in|init|inout|internal|is|let|nil|open|operator|private|protocol|public|repeat|rethrows|return|self|some|static|struct|subscript|super|switch|throw|throws|true|try|typealias|var|where|while"
        case .rust: words = "as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|unsafe|use|where|while"
        case .python: words = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
        case .javascript, .typescript: words = "async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|from|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|with|yield|interface|type|enum|implements|public|private|protected"
        case .logos: words = "if|else|for|while|return|static|const|void|id|BOOL|YES|NO|nil|self|super"
        case .go: words = "break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var"
        case .c, .cpp, .objc: words = "auto|break|case|char|class|const|continue|default|do|double|else|enum|extern|false|float|for|if|inline|int|long|namespace|new|nullptr|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while"
        case .zig: words = "align|allowzero|and|anyframe|anytype|asm|async|await|break|catch|comptime|const|continue|defer|else|enum|errdefer|error|export|extern|false|fn|for|if|inline|noalias|null|or|orelse|packed|pub|resume|return|struct|suspend|switch|test|threadlocal|true|try|union|unreachable|usingnamespace|var|volatile|while"
        case .java, .kotlin: words = "abstract|as|break|case|catch|class|const|continue|data|default|do|else|enum|extends|false|final|finally|for|fun|if|implements|import|in|interface|is|new|null|object|open|package|private|protected|public|return|static|super|switch|this|throw|throws|true|try|val|var|void|when|while"
        case .shell: words = "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|return|then|while"
        default: words = ""
        }
        return words.isEmpty ? "" : "\\b(?:" + words + ")\\b"
    }

    var typePattern: String {
        #"\b(?:String|Int|Int32|Int64|UInt|Bool|Double|Float|Character|URL|Data|Array|Dictionary|Set|Result|Optional|NSString|NSArray|NSDictionary|NSObject|UIView|UIViewController|CGFloat|size_t|uint\d+_t|int\d+_t)\b"#
    }
}
