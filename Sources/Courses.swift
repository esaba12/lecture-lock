import Foundation

// MARK: - Course presets

struct Course {
    let name: String
    let host: String
    let lessons: [(slug: String, title: String)]
    /// JS returning "<path>|~|<1 if this lesson is done>".
    let doneJS: String

    func index(ofURL url: String) -> Int? {
        guard let path = URLComponents(string: url)?.path else { return nil }
        return index(ofPath: path)
    }
    func index(ofPath path: String) -> Int? {
        let slug = path.split(separator: "/").last.map(String.init) ?? ""
        return lessons.firstIndex { $0.slug == slug }
    }
}

let courses: [Course] = [
    Course(
        name: "SQLBolt", host: "sqlbolt.com",
        lessons: [
            ("select_queries_introduction", "1 · SELECT queries 101"),
            ("select_queries_with_constraints", "2 · Constraints (Pt. 1)"),
            ("select_queries_with_constraints_pt_2", "3 · Constraints (Pt. 2)"),
            ("filtering_sorting_query_results", "4 · Filtering and sorting"),
            ("select_queries_review", "5 · Review: simple SELECTs"),
            ("select_queries_with_joins", "6 · JOINs"),
            ("select_queries_with_outer_joins", "7 · OUTER JOINs"),
            ("select_queries_with_nulls", "8 · NULLs"),
            ("select_queries_with_expressions", "9 · Expressions"),
            ("select_queries_with_aggregates", "10 · Aggregates (Pt. 1)"),
            ("select_queries_with_aggregates_pt_2", "11 · Aggregates (Pt. 2)"),
            ("select_queries_order_of_execution", "12 · Order of execution"),
            ("inserting_rows", "13 · Inserting rows"),
            ("updating_rows", "14 · Updating rows"),
            ("deleting_rows", "15 · Deleting rows"),
            ("creating_tables", "16 · Creating tables"),
            ("altering_tables", "17 · Altering tables"),
            ("dropping_tables", "18 · Dropping tables"),
        ],
        // A lesson's Continue button loses `disabled` once every exercise on it is solved.
        doneJS: "(function(){var c=document.querySelector('.continue');return location.pathname+'\(sep)'+(c&&!/disabled/.test(c.className)?1:0)})()"
    ),
]

func course(forURL url: String) -> Course? {
    let host = siteAnchor(url)
    return courses.first { host == $0.host || host.hasSuffix("." + $0.host) }
}
