import SwiftUI
import UIKit

/// UIKit bridge: multi line editor backed by UITextView, giving real cursor
/// and selection control that SwiftUI TextEditor lacks.
/// Best fit UIKit area three: recipe notes and Quick Update input.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var isEditable: Bool = true
    var isScrollEnabled: Bool = true
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingChanged: onEditingChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = isEditable
        textView.isScrollEnabled = isScrollEnabled
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = isEditable
        textView.isScrollEnabled = isScrollEnabled
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        private let onEditingChanged: (Bool) -> Void

        init(text: Binding<String>, onEditingChanged: @escaping (Bool) -> Void) {
            self.text = text
            self.onEditingChanged = onEditingChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onEditingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onEditingChanged(false)
        }
    }
}
