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
            highlight(text: textView.text, fileName: parent.fileName)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateSelection(textView)
            container?.updateCurrentLine()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
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
            let value = CodeEditorSelection(line: line, column: column, selectedLength: textView.selectedRange.length)
            if parent.selection != value { parent.selection = value }
        }

        func highlight(text: String, fileName: String) {
            guard let textView = container?.textView else { return }
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
            if language == .logos {
                apply(pattern: #"%\w+"#, color: .systemBlue, to: attributed)
            }
            applyingAttributes = true
            textView.attributedText = attributed
            textView.selectedRange = NSRange(location: min(selected.location, attributed.length), length: min(selected.length, max(0, attributed.length - min(selected.location, attributed.length))))
            applyingAttributes = false
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

private enum EditorLanguage: Equatable {
    case swift, objc, cpp, c, logos, rust, go, zig, python, javascript, typescript, java, kotlin, shell, json, yaml, generic

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
