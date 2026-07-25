import SwiftUI
import AppKit

class IntrinsicTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0
    
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        
        let newHeight = rect.height
        if abs(newHeight - lastReportedHeight) > 1 {
            lastReportedHeight = newHeight
            DispatchQueue.main.async {
                self.onHeightChange?(newHeight)
            }
        }
        
        return NSSize(width: NSView.noIntrinsicMetric, height: newHeight)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateIntrinsicContentSize()
    }
}

struct DynamicHeightTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> IntrinsicTextView {
        let textView = IntrinsicTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13) // macOS standard body
        textView.delegate = context.coordinator
        
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        
        textView.onHeightChange = { newHeight in
            if abs(self.height - newHeight) > 1 {
                self.height = newHeight
            }
        }
        
        return textView
    }

    func updateNSView(_ nsView: IntrinsicTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DynamicHeightTextField

        init(_ parent: DynamicHeightTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.invalidateIntrinsicContentSize()
        }
    }
}
