import CoreGraphics
import Foundation

/// Per-pane column widths for the file list. Lives in `mqdirCore` so that
/// persisted pane state (which embeds it) is fully testable headless.
struct PaneColumnWidths: Codable, Equatable, Sendable {
    var modified: CGFloat
    var size: CGFloat
    var kind: CGFloat
    // 创建日期列宽度，默认与 modified 同宽（132pt，短日期+短时间）
    var created: CGFloat

    init(
        modified: CGFloat = 132,
        size: CGFloat = 78,
        kind: CGFloat = 96,
        // created 宽度默认 132，与修改日期列宽完全一致（格式化器相同）
        created: CGFloat = 132
    ) {
        self.modified = modified
        self.size = size
        self.kind = kind
        self.created = created
    }

    static let modifiedRange: ClosedRange<CGFloat> = 72...260
    static let sizeRange: ClosedRange<CGFloat> = 56...140
    static let kindRange: ClosedRange<CGFloat> = 56...220
    // created 允许宽度合法范围与 modified 保持一致（同一类日期列）
    static let createdRange: ClosedRange<CGFloat> = 72...260
}
