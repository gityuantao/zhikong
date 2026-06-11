import AppKit

final class StatsOverlayView: NSView {
    private let label = NSTextField(labelWithString: "—")

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 6
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(fps: Double, width: Int, height: Int, latencyMs: Double) {
        label.stringValue = String(format: "%.0f fps · %d×%d · 延迟 %.0fms", fps, width, height, latencyMs)
    }
}
