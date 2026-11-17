import Foundation

extension ElicitationForm {
    /// The fields grouped into pages, one page per question. A `question_<n>_custom` field joins the page of the
    /// field right before it, so a question and its Other box stay together. Only AskUserQuestion forms are paged:
    /// when any field is not named `question_<n>` or `question_<n>_custom`, all fields share one page.
    var pages: [[ElicitationField]] {
        guard fields.allSatisfy({ $0.id.range(of: #"^question_\d+(_custom)?$"#, options: .regularExpression) != nil }) else {
            return [fields]
        }
        var result: [[ElicitationField]] = []
        for field in fields {
            if field.id.hasSuffix("_custom"), let last = result.last?.first, field.id == last.id + "_custom" {
                result[result.count - 1].append(field)
            } else {
                result.append([field])
            }
        }
        return result
    }

    /// The first page whose required fields are empty or whose number does not parse, or nil when the form can be submitted.
    func firstIncompletePage(_ answers: ElicitationAnswers) -> Int? {
        pages.firstIndex { !ElicitationForm(message: "", fields: $0).canSubmit(answers) }
    }
}

/// Which question the form card shows. A form with one page has no arrows and no indicator.
struct ElicitationPager: Equatable {
    let pageCount: Int
    private(set) var index = 0

    init(pageCount: Int) { self.pageCount = max(pageCount, 1) }

    var isPaged: Bool { pageCount > 1 }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < pageCount - 1 }
    var isLast: Bool { !canGoForward }
    var label: String { "\(index + 1) of \(pageCount)" }

    mutating func back() { if canGoBack { index -= 1 } }
    mutating func forward() { if canGoForward { index += 1 } }
    mutating func show(_ page: Int) { index = min(max(page, 0), pageCount - 1) }
}
