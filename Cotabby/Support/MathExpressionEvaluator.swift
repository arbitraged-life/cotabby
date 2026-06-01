import Foundation

/// Detects and evaluates inline math expressions for instant calculation autocomplete.
///
/// When the user types something like `20000/(1.09)^3 =` or `(45 + 67) * 2 =`, this evaluator
/// extracts the expression, computes it, and returns a formatted result that can short-circuit
/// the LLM generation pipeline.
///
/// Supports: +, -, *, /, ^, parentheses, decimal numbers, percentage (e.g. 15%), and `k`/`m`
/// suffixes (e.g. 20k = 20000, 1.5m = 1500000).
enum MathExpressionEvaluator {
    /// Attempts to detect and evaluate a math expression at the end of the given text.
    /// Returns the formatted result string if the text ends with a calculable expression followed by `=`,
    /// or `nil` if no math expression is detected.
    static func evaluate(precedingText: String) -> String? {
        let trimmed = precedingText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("=") else { return nil }

        // Extract expression before the `=`
        let beforeEquals = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !beforeEquals.isEmpty else { return nil }

        // Walk backwards to find the start of the expression (stop at newline or non-math chars)
        let expression = extractExpression(from: beforeEquals)
        guard !expression.isEmpty else { return nil }

        // Validate it looks like math (must contain at least one operator or function)
        guard looksLikeMath(expression) else { return nil }

        // Normalize and evaluate
        guard let result = computeResult(expression) else { return nil }

        return formatResult(result)
    }

    // MARK: - Private

    /// Extracts the math expression from the end of a line. Stops at characters that can't be
    /// part of an expression.
    private static func extractExpression(from text: String) -> String {
        // Take the last "line" (after the last newline)
        let lastLine: String
        if let nlRange = text.range(of: "\n", options: .backwards) {
            lastLine = String(text[nlRange.upperBound...])
        } else {
            lastLine = text
        }

        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)

        // Walk backwards from end, accepting: digits, operators, parens, spaces, dots, %, k, m, K, M, e, E
        let allowedChars = CharacterSet(charactersIn: "0123456789.+-*/^()% kKmMeE,")
        var startIndex = trimmed.endIndex
        for idx in trimmed.indices.reversed() {
            let scalar = trimmed.unicodeScalars[idx]
            if allowedChars.contains(scalar) {
                startIndex = idx
            } else {
                break
            }
        }

        let candidate = String(trimmed[startIndex...]).trimmingCharacters(in: .whitespaces)
        return candidate
    }

    /// Returns true if the string contains at least one arithmetic operator between operands.
    private static func looksLikeMath(_ expr: String) -> Bool {
        // Must have at least one operator: +, -, *, /, ^
        // But not just a single number
        let operators = CharacterSet(charactersIn: "+-*/^")
        let withoutLeadingSign: String
        if expr.first == "-" || expr.first == "+" {
            withoutLeadingSign = String(expr.dropFirst())
        } else {
            withoutLeadingSign = expr
        }
        return withoutLeadingSign.unicodeScalars.contains(where: { operators.contains($0) })
            || expr.contains("(")
    }

    /// Normalizes the expression and evaluates it using NSExpression.
    private static func computeResult(_ rawExpr: String) -> Double? {
        var expr = rawExpr

        // Expand k/K and m/M suffixes: "20k" → "20000", "1.5m" → "1500000"
        expr = expr.replacingOccurrences(
            of: #"(\d+\.?\d*)\s*[kK]"#,
            with: "($1*1000)",
            options: .regularExpression
        )
        expr = expr.replacingOccurrences(
            of: #"(\d+\.?\d*)\s*[mM]"#,
            with: "($1*1000000)",
            options: .regularExpression
        )

        // Expand percentage: "15%" → "(15/100)"
        expr = expr.replacingOccurrences(
            of: #"(\d+\.?\d*)%"#,
            with: "($1/100)",
            options: .regularExpression
        )

        // Replace ^ with ** (NSExpression power operator)
        expr = expr.replacingOccurrences(of: "^", with: "**")

        // Remove commas (thousands separators)
        expr = expr.replacingOccurrences(of: ",", with: "")

        // Remove spaces
        expr = expr.replacingOccurrences(of: " ", with: "")

        // Validate: only safe characters remain
        let safeChars = CharacterSet(charactersIn: "0123456789.+-*/()e")
        let filtered = expr.unicodeScalars.filter { safeChars.contains($0) }
        guard filtered.count == expr.unicodeScalars.count else { return nil }

        // Balanced parentheses check
        var depth = 0
        for ch in expr {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth < 0 { return nil }
        }
        guard depth == 0 else { return nil }

        // Evaluate with NSExpression
        guard let nsExpr = try? NSExpression(format: expr) else { return nil }
        guard let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }

        let value = result.doubleValue
        guard value.isFinite else { return nil }
        return value
    }

    /// Formats the result nicely — integer if whole, otherwise up to 6 decimal places (trimmed).
    private static func formatResult(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }

        // Use up to 6 decimal places, strip trailing zeros
        let formatted = String(format: "%.6f", value)
        var result = formatted
        while result.hasSuffix("0") { result = String(result.dropLast()) }
        if result.hasSuffix(".") { result = String(result.dropLast()) }

        // Add thousands separators for readability if large
        return result
    }
}
