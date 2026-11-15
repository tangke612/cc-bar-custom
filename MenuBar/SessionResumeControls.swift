import AppKit
import SwiftUI

// MARK: - CopyResumeCommandButton

/// 一键复制终端恢复命令按钮。
/// - 使用 AppKit `NSView` 点击层独立承接 `hitTest`，嵌套在可选中列表行或弹窗快捷行内时互不抢事件。
/// - 在菜单栏悬停弹窗中启用 `preventAppActivation = true`，通过 `acceptsFirstMouse` +
///   `shouldDelayWindowOrdering` + `NSApp.preventWindowOrdering()` 确保点击复制绝不抢占终端输入焦点。
/// - 点击后写入 `NSPasteboard.general` 并短暂展示“已复制”状态反馈。
struct CopyResumeCommandButton: View {
    let resumeCommand: SessionResumeCommand
    var compact: Bool = false
    var preventAppActivation: Bool = false
    var onHoverDesktopHintChange: ((Bool) -> Void)? = nil

    @State private var copied = false
    @State private var isHovered = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        buttonVisual
            .help(resumeCommand.helpText)
            .overlay {
                ResumeButtonClickOverlay(
                    toolTip: resumeCommand.helpText,
                    preventAppActivation: preventAppActivation,
                    isHovered: $isHovered,
                    onTap: performCopy
                )
            }
            .onChange(of: isHovered) { _, hovering in
                if resumeCommand.requiresDesktopResumeHint {
                    onHoverDesktopHintChange?(hovering)
                }
            }
    }

    private var buttonVisual: some View {
        HStack(spacing: compact ? 3.5 : 4.5) {
            Image(systemName: copied ? "checkmark" : "terminal")
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
            Text(copied ? tr("Copied", "已复制") : tr("Copy", "复制"))
                .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(
            copied
                ? PopoverPalette.barNormalFill
                : (isHovered ? PopoverPalette.primaryText : PopoverPalette.secondaryText)
        )
        .padding(.horizontal, compact ? 6.5 : 8)
        .padding(.vertical, compact ? 3 : 3.5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .fixedSize()
        .animation(.easeOut(duration: 0.14), value: copied)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        if copied {
            return Color.green.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.09)
        }
        return Color.primary.opacity(0.045)
    }

    private var borderColor: Color {
        if copied {
            return Color.green.opacity(0.35)
        }
        return Color.primary.opacity(isHovered ? 0.16 : 0.09)
    }

    private func performCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand.command, forType: .string)

        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - AppKit Click Overlay

private struct ResumeButtonClickOverlay: NSViewRepresentable {
    let toolTip: String
    let preventAppActivation: Bool
    @Binding var isHovered: Bool
    let onTap: () -> Void

    func makeNSView(context: Context) -> ResumeButtonClickNSView {
        let view = ResumeButtonClickNSView()
        view.toolTip = toolTip
        view.preventAppActivation = preventAppActivation
        view.onHoverChange = { hovering in
            isHovered = hovering
        }
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: ResumeButtonClickNSView, context: Context) {
        if nsView.toolTip != toolTip {
            nsView.toolTip = toolTip
        }
        nsView.preventAppActivation = preventAppActivation
        nsView.onHoverChange = { hovering in
            isHovered = hovering
        }
        nsView.onTap = onTap
    }
}

final class ResumeButtonClickNSView: NSView {
    var preventAppActivation: Bool = false
    var onHoverChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        preventAppActivation
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreaRef == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if preventAppActivation {
            // 阻止点击按钮时激活 CCBar 进程或提升窗口层级，保护终端当前键盘输入焦点。
            NSApp.preventWindowOrdering()
        }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isPressed else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -2, dy: -2).contains(localPoint) {
            onTap?()
        }
    }
}

// MARK: - PopoverSearchField (Click-to-Activate Focus & Pause Auto-Dismiss)

/// 悬停弹窗专用搜索框：
/// 平时不抢焦点；仅当用户主动点击输入框准备检索时，触发 `onActivateFocus` 调用 `NSApp.activate`
/// 获取键盘焦点并暂停弹窗自动收起；按 `Esc` 触发 `onEscape` 恢复收起。
struct PopoverSearchField: View {
    let placeholder: String
    @Binding var text: String
    let onActivateFocus: () -> Void
    let onEscape: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PopoverPalette.secondaryText)

            ActivatingTextFieldRepresentable(
                placeholder: placeholder,
                text: $text,
                onActivateFocus: onActivateFocus,
                onEscape: onEscape
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PopoverPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(tr("Clear search", "清空搜索"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ActivatingTextFieldRepresentable: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onActivateFocus: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> ActivatingSearchNSTextField {
        let field = ActivatingSearchNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.applyReadablePlaceholder(placeholder)
        field.delegate = context.coordinator
        field.onActivateFocus = onActivateFocus
        return field
    }

    func updateNSView(_ nsView: ActivatingSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEscape = onEscape
        nsView.onActivateFocus = onActivateFocus
        if nsView.currentPlaceholder != placeholder {
            nsView.applyReadablePlaceholder(placeholder)
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEscape: () -> Void

        init(text: Binding<String>, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            MenuBarStatusController.shared.endSearchFocusIfUnpinned()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }
    }
}

final class ActivatingSearchNSTextField: NSTextField {
    var onActivateFocus: (() -> Void)?
    private(set) var currentPlaceholder: String = ""

    override var allowsVibrancy: Bool { false }

    func applyReadablePlaceholder(_ text: String) {
        currentPlaceholder = text
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // 用户主动点击搜索框：激活应用并将 Popover 置为 key window，使其可正常打字输入。
        onActivateFocus?()
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}
