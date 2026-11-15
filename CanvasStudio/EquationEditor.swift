import SwiftUI
import UIKit

struct EquationEditor: View {
    @ObservedObject var store: NotebookStore
    let objectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var fontSize: Double = 30
    @State private var color = UIColor.label
    @State private var fitSize = true
    @State private var showGuide = false
    @State private var saveError = ""
    private var diagnostic: EquationDiagnostic? { EquationRenderer.diagnostic(source) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preview").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text("Updates as you write").font(.caption).foregroundStyle(.tertiary)
                    }
                    EquationPreview(source: source, fontSize: CGFloat(fontSize), color: color)
                        .frame(minHeight: 85, idealHeight: 140, maxHeight: 180)
                        .accessibilityIdentifier("equationPreview")
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    if let diagnostic {
                        Label(diagnostic.localizedDescription, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("equationDiagnostic")
                    } else {
                        Label(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Write an equation below" : "Equation is ready", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
                Divider()
                HStack {
                    Text("LaTeX").font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("Fit equation size", isOn: $fitSize).font(.caption).fixedSize()
                }.padding(.horizontal, 22).padding(.vertical, 12)
                EquationSourceEditor(text: $source)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .frame(minHeight: 100, maxHeight: .infinity)
                if !saveError.isEmpty { Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 10) }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Equation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("Supported equation notation") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                        .disabled(diagnostic != nil || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveEquation")
                }
            }
            .onAppear {
                if let object = store.notebook.objects.first(where: { $0.id == objectID }) {
                    source = object.text; fontSize = object.properties["fontSize"] ?? 30; color = UIColor(studioHex: object.color)
                }
            }
            .sheet(isPresented: $showGuide) { EquationGuide() }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func save() {
        guard var object = store.notebook.objects.first(where: { $0.id == objectID }) else { saveError = "This equation was removed from the notebook."; return }
        do {
            let layout = try EquationRenderer.layout(source, fontSize: CGFloat(fontSize))
            object.text = source
            if fitSize { object.width = Double(max(40, layout.width + 12)); object.height = Double(max(36, layout.size.height + 12)) }
            try NotebookValidation.validate(object)
            store.update(object); dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

struct EquationPreview: UIViewRepresentable {
    var source: String
    var fontSize: CGFloat = 30
    var color: UIColor = .label
    func makeUIView(context: Context) -> EquationPreviewView { EquationPreviewView() }
    func updateUIView(_ view: EquationPreviewView, context: Context) { view.source = source; view.fontSize = fontSize; view.ink = color; view.setNeedsDisplay() }
}
final class EquationPreviewView: UIView {
    var source = ""
    var fontSize: CGFloat = 30
    var ink = UIColor.label
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let color = traitCollection.userInterfaceStyle == .dark && ink.studioLuminance < 0.22 ? UIColor.label : ink
        EquationRenderer.draw(source, in: bounds.insetBy(dx: 18, dy: 14), context: context, color: color, fontSize: fontSize, centered: true)
    }
}

private struct EquationTemplate {
    var label: String
    var accessible: String
    var empty: String
    var selected: String? = nil
    static let all: [EquationTemplate] = [
        .init(label: "a⁄b", accessible: "Insert fraction", empty: "\\frac{¦}{}", selected: "\\frac{§}{¦}"),
        .init(label: "x²", accessible: "Insert superscript", empty: "^{¦}", selected: "{§}^{¦}"),
        .init(label: "xₙ", accessible: "Insert subscript", empty: "_{¦}", selected: "{§}_{¦}"),
        .init(label: "√", accessible: "Insert square root", empty: "\\sqrt{¦}", selected: "\\sqrt{§}¦"),
        .init(label: "∫", accessible: "Insert integral", empty: "\\int_{0}^{1} ¦\\,dx", selected: "\\int_{0}^{1} {§}\\,dx¦"),
        .init(label: "∑", accessible: "Insert sum", empty: "\\sum_{n=1}^{N} ¦", selected: "\\sum_{n=1}^{N} {§}¦"),
        .init(label: "( )", accessible: "Insert scalable parentheses", empty: "\\left(¦\\right)", selected: "\\left(§\\right)¦"),
        .init(label: "α", accessible: "Insert alpha", empty: "\\alpha ¦"),
        .init(label: "θ", accessible: "Insert theta", empty: "\\theta ¦"),
        .init(label: "π", accessible: "Insert pi", empty: "\\pi ¦"),
        .init(label: "sin", accessible: "Insert sine", empty: "\\sin\\left(¦\\right)", selected: "\\sin\\left(§\\right)¦"),
        .init(label: "∞", accessible: "Insert infinity", empty: "\\infty ¦"),
        .init(label: "{ }", accessible: "Insert grouping braces", empty: "{¦}", selected: "{§}¦"),
        .init(label: "→", accessible: "Insert arrow", empty: "\\to ¦"),
        .init(label: "±", accessible: "Insert plus or minus", empty: "\\pm ¦"),
        .init(label: "⃗v", accessible: "Insert vector accent", empty: "\\vec{¦}", selected: "\\vec{§}¦")
    ]
}

/// UITextView keeps a real insertion point and selection for the native math accessory.
private struct EquationSourceEditor: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator; context.coordinator.view = view
        view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 12
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true; view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.accessibilityLabel = "LaTeX source"; view.accessibilityIdentifier = "equationSource"
        view.inputAccessoryView = context.coordinator.accessory()
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.binding = $text
        if view.text != text { let selection = view.selectedRange; view.text = text; view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0) }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<String>
        weak var view: UITextView?
        init(text: Binding<String>) { binding = text }
        func textViewDidChange(_ textView: UITextView) { binding.wrappedValue = textView.text }
        func accessory() -> UIView {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 54))
            bar.backgroundColor = .secondarySystemBackground
            let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.translatesAutoresizingMaskIntoConstraints = false
            let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 7; stack.alignment = .center; stack.translatesAutoresizingMaskIntoConstraints = false
            for template in EquationTemplate.all {
                var configuration = UIButton.Configuration.gray(); configuration.title = template.label
                configuration.baseForegroundColor = .label; configuration.cornerStyle = .medium
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.insert(template) })
                button.accessibilityLabel = template.accessible
                stack.addArrangedSubview(button)
            }
            let done = UIButton(type: .system); done.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            done.accessibilityLabel = "Dismiss keyboard"; done.translatesAutoresizingMaskIntoConstraints = false
            done.addAction(UIAction { [weak self] _ in self?.view?.resignFirstResponder() }, for: .touchUpInside)
            bar.addSubview(scroll); scroll.addSubview(stack); bar.addSubview(done)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), scroll.topAnchor.constraint(equalTo: bar.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor), scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
                done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8), done.widthAnchor.constraint(equalToConstant: 42), done.topAnchor.constraint(equalTo: bar.topAnchor), done.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
            ])
            return bar
        }
        private func insert(_ template: EquationTemplate) {
            guard let view else { return }
            let range = view.selectedRange, original = view.text as NSString
            guard NSMaxRange(range) <= original.length else { return }
            let selection = original.substring(with: range)
            let pattern = selection.isEmpty ? template.empty : (template.selected ?? template.empty)
            let withSelection = pattern.replacingOccurrences(of: "§", with: selection)
            let caret = (withSelection as NSString).range(of: "¦").location
            let insertion = withSelection.replacingOccurrences(of: "¦", with: "")
            if let textRange = view.selectedTextRange { view.replace(textRange, withText: insertion) }
            else { view.text = original.replacingCharacters(in: range, with: insertion) }
            view.selectedRange = NSRange(location: range.location + (caret == NSNotFound ? (insertion as NSString).length : caret), length: 0)
            binding.wrappedValue = view.text
            view.scrollRangeToVisible(view.selectedRange)
        }
    }
}

private struct EquationGuide: View {
    @Environment(\.dismiss) private var dismiss
    private let examples: [(String, String)] = [
        ("Fractions", #"\frac{a+b}{c}"#), ("Powers and indices", #"x^{2}+a_{n+1}"#),
        ("Roots", #"\sqrt{x^2+y^2}\quad\sqrt[3]{x}"#),
        ("Integrals", #"\int_{0}^{\infty} e^{-x}\,dx"#),
        ("Sums and limits", #"\sum_{n=1}^{N}n\quad\lim_{x\to 0}\frac{\sin x}{x}"#),
        ("Greek and functions", #"\alpha+\beta=\theta\quad\sin(\omega t)"#),
        ("Scalable delimiters", #"\left(\frac{x}{y}\right)"#),
        ("Accents and text", #"\vec{v}\quad\hat{x}\quad\text{for all }x"#)
    ]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Use the keyboard’s math row to insert common structures at the cursor. Select source first to wrap it in a fraction, root, or script.")
                }
                ForEach(examples, id: \.0) { title, source in
                    Section(title) {
                        EquationPreview(source: source, fontSize: 26).frame(height: 90)
                        Text(source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section("Supported notation") {
                    Text("This native typesetter supports grouped arithmetic, fractions, roots, upper and lower scripts, large operators and limits, Greek letters, common functions and relations, scalable delimiters, accents, and simple text styles. Use \\\\ to start a new equation line.")
                    Text("Matrices, alignment environments, custom macros, packages, and full document LaTeX are not supported. Unknown commands and unbalanced groups show an error instead of silently changing the equation.").foregroundStyle(.secondary)
                }
            }.navigationTitle("Writing equations").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
