import SwiftUI
import AppKit

/// NSComboBox keeps native editing and dropdown behavior, including system input methods.
struct PlannerModelComboBox: NSViewRepresentable {
    @Binding var text: String
    let options: [String]
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox(frame: .zero)
        box.isEditable = true; box.completes = false; box.usesDataSource = true
        box.numberOfVisibleItems = 10; box.controlSize = .regular
        box.dataSource = context.coordinator; box.delegate = context.coordinator
        box.setAccessibilityLabel("规划模型")
        box.placeholderString = "输入或选择模型 ID"
        box.stringValue = text; box.isEnabled = isEnabled
        context.coordinator.applyOptions(options, to: box)
        return box
    }
    func updateNSView(_ box: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; box.isEnabled = isEnabled
        let editor = box.currentEditor() as? NSTextView
        if box.stringValue != text, editor?.hasMarkedText() != true {
            coordinator.isUpdating = true; box.stringValue = text; coordinator.isUpdating = false
        }
        coordinator.applyOptions(options, to: box)
    }
    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: PlannerModelComboBox
        var isUpdating = false
        private var options: [String] = []
        private var pendingOptions: [String]?
        init(_ parent: PlannerModelComboBox) { self.parent = parent }
        func numberOfItems(in comboBox: NSComboBox) -> Int { options.count }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            options.indices.contains(index) ? options[index] : nil
        }
        func applyOptions(_ next: [String], to box: NSComboBox) {
            guard next != options else { pendingOptions = nil; return }
            let editor = box.currentEditor() as? NSTextView
            guard editor?.hasMarkedText() != true else { pendingOptions = next; return }
            let value = box.stringValue, editingText = editor?.string, selection = editor?.selectedRange()
            isUpdating = true
            options = next; pendingOptions = nil; box.reloadData()
            // Reload suggestions without changing typed text, the insertion point or selection.
            if box.stringValue != value { box.stringValue = value }
            if let editor, let editingText, editor.string != editingText { editor.string = editingText }
            if let editor, let selection { editor.setSelectedRange(selection) }
            isUpdating = false
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
            if let pendingOptions { applyOptions(pendingOptions, to: box) }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isUpdating, let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
            if let pendingOptions { applyOptions(pendingOptions, to: box) }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let box = notification.object as? NSComboBox,
                  options.indices.contains(box.indexOfSelectedItem) else { return }
            let selected = options[box.indexOfSelectedItem]
            box.stringValue = selected; parent.text = selected
        }
    }
}
