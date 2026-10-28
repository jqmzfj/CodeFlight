import AppKit
import Foundation

/// Immutable UTF-16 token intervals, prepared off the UI thread. Visible-line
/// queries use binary search; scrolling never rescans the preceding document.
struct CodeSyntaxIndex: Sendable {
    enum Kind: Sendable { case string, comment }
    struct Token: Sendable {
        let range: NSRange
        let kind: Kind
    }
    let language: String
    let tokens: [Token]
    var storageCost: Int { tokens.count * MemoryLayout<Token>.stride }

    func tokens(in range: NSRange) -> [Token] {
        var lower = 0, upper = tokens.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(tokens[middle].range) <= range.location { lower = middle + 1 }
            else { upper = middle }
        }
        var result: [Token] = []
        while lower < tokens.count, tokens[lower].range.location < NSMaxRange(range) {
            let token = tokens[lower]
            let overlap = NSIntersectionRange(token.range, range)
            if overlap.length > 0 {
                result.append(Token(range: NSRange(location: overlap.location - range.location, length: overlap.length), kind: token.kind))
            }
            lower += 1
        }
        return result
    }

    static func prepare(_ text: String, language: String) -> CodeSyntaxIndex {
        let c: Set<String> = ["swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "go", "rs", "php", "c", "h", "cpp", "hpp", "cs", "json", "jsonc", "sql", "kt", "kts", "scala", "dart", "vue", "svelte"]
        let xml: Set<String> = ["xml", "html", "xhtml"]
        let hash: Set<String> = ["py", "sh", "bash", "zsh", "yaml", "yml", "toml", "rb", "r", "env", "conf", "ini"]
        guard c.contains(language) || xml.contains(language) || hash.contains(language), !Task.isCancelled else {
            return CodeSyntaxIndex(language: language, tokens: [])
        }
        let units = Array(text.utf16)
        let count = units.count
        var tokens: [Token] = []
        var i = 0
        var nextCancellationCheck = 0
        func matches(_ delimiter: [UInt16], at position: Int) -> Bool {
            guard position + delimiter.count <= count else { return false }
            for offset in delimiter.indices where units[position + offset] != delimiter[offset] { return false }
            return true
        }
        let slashComments = c.contains(language) && language != "sql" && language != "json"
        let blockComments = slashComments || language == "sql"
        let nested = ["swift", "rs", "kt", "kts", "scala"].contains(language)
        while i < count {
            if i >= nextCancellationCheck {
                nextCancellationCheck = i + 4096
                if Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
            }
            let start = i
            let ch = units[i]
            if xml.contains(language), matches([60, 33, 45, 45], at: i) {
                i += 4
                while i < count, !matches([45, 45, 62], at: i) {
                    if i >= nextCancellationCheck {
                        nextCancellationCheck = i + 4096
                        if Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
                    }
                    i += 1
                }
                if i < count { i += 3 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            if (slashComments && matches([47,47], at: i)) || (language == "sql" && matches([45,45], at: i)) || ((hash.contains(language) || language == "php") && ch == 35) {
                while i < count, units[i] != 10 {
                    if i >= nextCancellationCheck {
                        nextCancellationCheck = i + 4096
                        if Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
                    }
                    i += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            if blockComments && matches([47,42], at: i) {
                i += 2
                var depth = 1
                while i < count, depth > 0 {
                    if i >= nextCancellationCheck {
                        nextCancellationCheck = i + 4096
                        if Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
                    }
                    if nested && matches([47,42], at: i) { depth += 1; i += 2 }
                    else if matches([42,47], at: i) { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            // Swift raw delimiters must be recognized before # can be treated
            // as ordinary source. No full-file regex or backtracking is used.
            var hashes = 0
            if language == "swift" {
                while i + hashes < count, units[i + hashes] == 35 {
                    hashes += 1
                    if hashes & 4095 == 0, Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
                }
            }
            let quotePosition = i + hashes
            let quote = quotePosition < count ? units[quotePosition] : 0
            if hashes > 0, quote != 34 { i += hashes; continue }
            let backtick = quote == 96 && ["go", "js", "mjs", "cjs", "ts", "tsx", "jsx", "php"].contains(language)
            let single = quote == 39 && language != "swift" && language != "json" && language != "jsonc"
            if quote == 34 || single || backtick {
                let triple = ["py", "swift", "toml", "java", "kt", "kts", "scala"].contains(language) && matches([quote,quote,quote], at: quotePosition)
                let delimiter = Array(repeating: quote, count: triple ? 3 : 1) + Array(repeating: UInt16(35), count: hashes)
                let multiline = triple || backtick || ["sql", "php", "sh", "bash", "zsh", "rb"].contains(language)
                let escape = [UInt16(92)] + Array(repeating: UInt16(35), count: hashes)
                i = quotePosition + (triple ? 3 : 1)
                while i < count {
                    if i >= nextCancellationCheck {
                        nextCancellationCheck = i + 4096
                        if Task.isCancelled { return CodeSyntaxIndex(language: language, tokens: []) }
                    }
                    if matches(delimiter, at: i) {
                        // SQL quotes escape themselves by doubling.
                        if language == "sql", i + 1 < count, units[i+1] == quote { i += 2; continue }
                        i += delimiter.count; break
                    }
                    if !multiline && units[i] == 10 { break }
                    if !(language == "go" && backtick), language != "sql", matches(escape, at: i) {
                        i = min(count, i + escape.count + 1)
                    } else { i += 1 }
                }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            }
            i += 1
        }
        return CodeSyntaxIndex(language: language, tokens: tokens)
    }
}

@MainActor
enum SyntaxHighlighter {
    private static let cStyle: NSRegularExpression? = try? NSRegularExpression(pattern: #"(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(?<comment>//.*$|/\*.*?\*/)|(?<keyword>\b(?:import|from|as|actor|some|any|associatedtype|mutating|nonmutating|nonisolated|weak|unowned|lazy|where|init|deinit|subscript|get|set|willSet|didSet|is|rethrows|convenience|required|struct|class|enum|protocol|extension|func|function|def|return|if|else|elif|for|while|in|switch|case|default|guard|let|var|const|type|interface|async|await|try|catch|throw|throws|new|public|private|protected|internal|static|final|override|package|namespace|using|void|int|string|bool|break|continue|defer|do|catch|implements|extends|export|SELECT|FROM|WHERE|INSERT|INTO|UPDATE|DELETE|CREATE|TABLE|JOIN|LEFT|RIGHT|ON|GROUP|BY|ORDER|LIMIT|AND|OR)\b)|(?<literal>\b(?:true|false|null|nil|undefined|None|self|this)\b)|(?<number>(?<![\p{L}\p{M}\p{N}\p{Pc}\p{So}\p{Sk}$])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![\p{L}\p{M}\p{N}\p{Pc}\p{So}\p{Sk}$]))"#)
    private static let hashStyle: NSRegularExpression? = try? NSRegularExpression(pattern: #"(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(?<comment>[#].*$)|(?<keyword>\b(?:import|from|as|class|def|return|if|else|elif|for|while|in|with|pass|raise|except|finally|try|async|await|lambda|yield|global|nonlocal|and|or|not|is|then|fi|do|done|export|function|case|esac)\b)|(?<literal>\b(?:true|false|null|nil|None|True|False|self)\b)|(?<number>(?<![\p{L}\p{M}\p{N}\p{Pc}\p{So}\p{Sk}$])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![\p{L}\p{M}\p{N}\p{Pc}\p{So}\p{Sk}$]))"#)
    // XML/POM files use a compact tag grammar rather than C-style keywords.
    // Keeping this expression line-safe lets the visible-line renderer color
    // large build files without scanning the entire document on the main actor.
    private static let xmlStyle: NSRegularExpression? = try? NSRegularExpression(pattern: #"(?<comment><!--[\s\S]*?-->)|(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<keyword></?[A-Za-z_:][A-Za-z0-9_.:-]*)|(?<type>\b[A-Za-z_:][A-Za-z0-9_.:-]*(?=\s*=))|(?<literal>\b(?:true|false|null)\b)|(?<number>\b\d+(?:\.\d+)?\b)"#)
    private static let cLanguages: Set<String> = ["swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "go", "rs", "php", "c", "h", "cpp", "hpp", "cs", "json", "jsonc", "sql", "kt", "kts", "scala", "dart", "vue", "svelte"]
    private static let hashLanguages: Set<String> = ["py", "sh", "bash", "zsh", "yaml", "yml", "toml", "rb", "r", "env", "conf", "ini"]
    private static let xmlLanguages: Set<String> = ["xml", "html", "xhtml"]
    // Declaration names get the blue accent used by Xcode's source editor.
    // The expression is optional so a future Foundation regex change cannot
    // make preview rendering fail.
    private static let declarationStyle: NSRegularExpression? = try? NSRegularExpression(pattern: #"\b(?:class|struct|enum|protocol|interface|typealias)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#)

    static func attributed(_ text: String, language: String, search: String = "", protectedTokens: [CodeSyntaxIndex.Token]? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        guard text.utf8.count <= 8192 else { return result }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let lexer = xmlLanguages.contains(language) ? xmlStyle : hashLanguages.contains(language) ? hashStyle : cLanguages.contains(language) ? cStyle : nil
        let protected = protectedTokens ?? CodeSyntaxIndex.prepare(text, language: language).tokens
        var gaps: [NSRange] = []
        var cursor = 0
        for token in protected {
            if token.range.location > cursor { gaps.append(NSRange(location: cursor, length: token.range.location - cursor)) }
            cursor = NSMaxRange(token.range)
        }
        if cursor < range.length { gaps.append(NSRange(location: cursor, length: range.length - cursor)) }
        for gap in gaps {
            lexer?.enumerateMatches(in: text, range: gap) { match, _, _ in
                guard let match else { return }
                let colors: [(String, NSColor)] = [("string", SyntaxPalette.string), ("comment", SyntaxPalette.comment), ("keyword", SyntaxPalette.keyword), ("type", SyntaxPalette.type), ("literal", SyntaxPalette.keyword), ("number", SyntaxPalette.number)]
                for (name, color) in colors {
                    let token = match.range(withName: name)
                    if token.location != NSNotFound { result.addAttribute(.foregroundColor, value: color, range: token); break }
                }
            }
            declarationStyle?.enumerateMatches(in: text, range: gap) { match, _, _ in
                guard let match else { return }
                let name = match.range(at: 1)
                guard name.location != NSNotFound else { return }
                result.addAttribute(.foregroundColor, value: SyntaxPalette.type, range: name)
            }
        }
        for token in protected {
            result.addAttribute(.foregroundColor, value: token.kind == .comment ? SyntaxPalette.comment : SyntaxPalette.string, range: token.range)
        }
        if language == "md", text.trimmingCharacters(in: .whitespaces).hasPrefix("#") { result.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range) }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var remaining = range
            let source = text as NSString
            while remaining.length > 0 {
                let found = source.range(of: search, options: [.caseInsensitive], range: remaining)
                guard found.location != NSNotFound, found.length > 0 else { break }
                result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: found)
                let end = NSMaxRange(found); remaining = NSRange(location: end, length: source.length - end)
            }
        }
        return result
    }
}


/// JetBrains-inspired semantic colors with separate WebStorm light and
/// PHPStorm Darcula dark palettes. The colors stay semantic so every supported
/// language keeps the same visual grammar.
@MainActor
enum SyntaxPalette {
    static let keyword = color("keyword", light: (0.46, 0.18, 0.60), dark: (0.80, 0.48, 0.20))
    static let type = color("type", light: (0.00, 0.32, 0.68), dark: (1.00, 0.79, 0.42))
    static let string = color("string", light: (0.02, 0.42, 0.12), dark: (0.42, 0.62, 0.36))
    static let comment = color("comment", light: (0.42, 0.44, 0.46), dark: (0.50, 0.50, 0.50))
    static let number = color("number", light: (0.08, 0.28, 0.72), dark: (0.41, 0.61, 0.76))
    private static func color(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: NSColor.Name("Workbench.syntax." + name)) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}
