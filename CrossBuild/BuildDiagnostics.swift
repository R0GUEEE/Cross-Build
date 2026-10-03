import Foundation

enum BuildDiagnosticSeverity: String, Codable, Sendable { case error, warning, note }

struct BuildDiagnostic: Identifiable, Codable, Sendable {
    let id: UUID
    var severity: BuildDiagnosticSeverity
    var tool: String
    var file: String?
    var line: Int?
    var column: Int?
    var message: String
    var code: String?
    init(severity:BuildDiagnosticSeverity,tool:String,file:String?=nil,line:Int?=nil,column:Int?=nil,message:String,code:String?=nil) {
        id=UUID(); self.severity=severity; self.tool=tool; self.file=file; self.line=line; self.column=column; self.message=message; self.code=code
    }
}

enum BuildDiagnosticParser {
    private static let clang = try! NSRegularExpression(pattern:#"^(.+?):(\d+):(\d+):\s+(error|warning|note):\s+(.+)$"#)
    private static let generic = try! NSRegularExpression(pattern:#"^(error|warning|note)(?:\[[^\]]+\])?:\s+(.+)$"#,options:.caseInsensitive)

    static func parse(_ text:String, tool:String) -> [BuildDiagnostic] {
        text.components(separatedBy:.newlines).compactMap { line in
            let range=NSRange(line.startIndex..<line.endIndex,in:line)
            if let m=clang.firstMatch(in:line,range:range),
               let fr=Range(m.range(at:1),in:line), let lr=Range(m.range(at:2),in:line),
               let cr=Range(m.range(at:3),in:line), let sr=Range(m.range(at:4),in:line), let mr=Range(m.range(at:5),in:line) {
                return BuildDiagnostic(severity:severity(String(line[sr])),tool:tool,file:String(line[fr]),line:Int(line[lr]),column:Int(line[cr]),message:String(line[mr]))
            }
            if let m=generic.firstMatch(in:line,range:range), let sr=Range(m.range(at:1),in:line), let mr=Range(m.range(at:2),in:line) {
                return BuildDiagnostic(severity:severity(String(line[sr])),tool:tool,message:String(line[mr]))
            }
            return nil
        }
    }

    private static func severity(_ value:String)->BuildDiagnosticSeverity {
        switch value.lowercased() { case "warning": return .warning; case "note": return .note; default: return .error }
    }
}
