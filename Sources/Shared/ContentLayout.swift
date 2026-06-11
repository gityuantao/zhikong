import CoreGraphics

/// 远端画面在视图里的内容矩形几何 —— Host 预览与 Client 远控**共用同一套**纯函数,
/// 保证"画到哪"(displayLayer.frame)和"点到哪"(归一化映射)用完全一致的几何,否则点击错位。
///
/// 坐标系:视图为 AppKit 默认**左下原点、y 向上**(非翻转)。
enum ContentLayout {
    /// 计算视频内容矩形(视图坐标,左下原点)。
    /// - letterbox(fillHeight=false):等比缩放完整放入 bounds,四周可能黑边(等价 AVMakeRect)。
    /// - 填高(fillHeight=true):等比缩放使**高度填满** bounds;宽度按比例,超宽时溢出 bounds 两侧。
    ///   `panX`(0…maxPanX)为水平平移量:把内容向左推以查看更靠右的部分,矩形 minX = bounds.minX - panX。
    static func rect(videoSize: CGSize, bounds: CGRect, fillHeight: Bool, panX: CGFloat) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let aspect = videoSize.width / videoSize.height

        if !fillHeight {
            // letterbox:等价 AVMakeRect(aspectRatio:insideRect:),居中。
            let boundsAspect = bounds.width / bounds.height
            var w = bounds.width, h = bounds.height
            if aspect > boundsAspect { h = bounds.width / aspect } else { w = bounds.height * aspect }
            return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                          y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
        }

        // 填高:高度 = bounds.height,宽度按比例。
        let h = bounds.height
        let w = h * aspect
        if w <= bounds.width {
            // 没溢出(画面比窗口窄)→ 水平居中,无需平移。
            return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY, width: w, height: h)
        }
        let maxPan = w - bounds.width
        let clampedPan = min(max(0, panX), maxPan)
        return CGRect(x: bounds.minX - clampedPan, y: bounds.minY, width: w, height: h)
    }

    /// 最大可平移量(内容宽度超出 bounds 的部分);≤0 表示无需/不能平移。
    static func maxPanX(videoSize: CGSize, bounds: CGRect, fillHeight: Bool) -> CGFloat {
        guard fillHeight, videoSize.width > 0, videoSize.height > 0, bounds.height > 0 else { return 0 }
        let w = bounds.height * (videoSize.width / videoSize.height)
        return max(0, w - bounds.width)
    }

    /// 视图内一点 → 归一化 `(nx, ny)`(均 0…1,**左上原点**:ny=0 内容顶、ny=1 内容底),
    /// 点落在内容矩形外返回 nil。`content` 取自上面的 `rect(...)`。
    /// 视图是左下原点,故 ny 翻转:`(content.maxY - p.y)/height` 使内容上沿对应 ny=0。
    static func normalize(point p: CGPoint, content: CGRect) -> (nx: Double, ny: Double)? {
        guard content.width > 0, content.height > 0 else { return nil }
        let nx = Double((p.x - content.minX) / content.width)
        let ny = Double((content.maxY - p.y) / content.height)
        guard (0.0...1.0).contains(nx), (0.0...1.0).contains(ny) else { return nil }
        return (nx, ny)
    }
}
