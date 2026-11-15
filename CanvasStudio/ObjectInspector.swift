import SwiftUI

struct ObjectInspector: View {
    @ObservedObject var store: NotebookStore
    var onClose: () -> Void
    @State private var codeObject: CanvasObject?
    private let accent = Color(red: 0.39, green: 0.31, blue: 0.83)
    private let colors = ["#334155", "#2563EB", "#7C3AED", "#10B981", "#F59E0B", "#EF4444", "#EC4899"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(accent)
                Text("Object").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(7).background(.quaternary, in: Circle()) }
                    .accessibilityLabel("Close object inspector")
            }.padding(18)
            Divider()
            if let object = store.selectedObjects.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if store.selectedIDs.count > 1 {
                            Label("\(store.selectedIDs.count) objects selected", systemImage: "square.stack.3d.up")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            caption(object.kind == "widget" ? "INTERACTIVE OBJECT" : object.kind.uppercased())
                            TextField("Object name", text: stringBinding(object, \.title))
                                .font(.system(size: 16, weight: .semibold)).textFieldStyle(.roundedBorder)
                        }
                        if ["text", "latex", "graph"].contains(object.kind) {
                            VStack(alignment: .leading, spacing: 8) {
                                caption(object.kind == "graph" ? "EXPRESSION" : object.kind == "latex" ? "LATEX SOURCE" : "TEXT")
                                TextField(object.kind == "graph" ? "sin(x)" : "Write something", text: stringBinding(object, \.text), axis: .vertical)
                                    .font(object.kind == "text" ? .callout : .system(.callout, design: .monospaced))
                                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                                if object.kind == "graph" { Text("Use x, sin, cos, tan, sqrt, exp, log and powers.").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            caption("COLOR")
                            HStack(spacing: 8) {
                                ForEach(colors, id: \.self) { hex in
                                    Button { update(object.id) { $0.color = hex } } label: {
                                        Circle().fill(Color(uiColor: UIColor(studioHex: hex)))
                                            .frame(width: 24, height: 24)
                                            .overlay { if object.color.lowercased() == hex.lowercased() { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                                    }.buttonStyle(.plain).accessibilityLabel("Color \(hex)")
                                }
                            }
                            ColorPicker("Custom color", selection: Binding(get: { Color(uiColor: UIColor(studioHex: latest(object).color)) }, set: { color in
                                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                                update(object.id) { $0.color = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
                            }), supportsOpacity: false).font(.caption)
                        }
                        if object.kind == "graph" {
                            VStack(alignment: .leading, spacing: 14) {
                                caption("LIVE PARAMETERS")
                                parameter(object, key: "amplitude", label: "Amplitude", fallback: 1, range: 0.1...5)
                                parameter(object, key: "frequency", label: "Frequency", fallback: 1, range: 0.1...5)
                                parameter(object, key: "c", label: "Vertical shift · C", fallback: 0, range: -5...5)
                            }
                        }
                        if object.kind == "shape" {
                            VStack(alignment: .leading, spacing: 12) {
                                caption("APPEARANCE")
                                Picker("Fill", selection: stringBinding(object, \.pattern)) {
                                    Text("Solid").tag("solid")
                                    Text("Starry").tag("stars")
                                }.pickerStyle(.segmented)
                                if object.shape == "triangle" {
                                    parameter(object, key: "angleA", label: "Angle A", fallback: 49, range: 1...max(1, 179 - (object.properties["angleB"] ?? 52)), integer: true)
                                    parameter(object, key: "angleB", label: "Angle B", fallback: 52, range: 1...max(1, 179 - (object.properties["angleA"] ?? 49)), integer: true)
                                    HStack { Text("Angle C").foregroundStyle(.secondary); Spacer(); Text(String(format: "%.0f°", 180 - (object.properties["angleA"] ?? 49) - (object.properties["angleB"] ?? 52))).monospacedDigit() }.font(.caption)
                                }
                            }
                        }
                        if ["text", "latex"].contains(object.kind) {
                            parameter(object, key: "fontSize", label: "Text size", fallback: object.kind == "latex" ? 27 : 20, range: 10...72, integer: true)
                        }
                        if object.kind == "widget" || hasExtraProperties(object) {
                            VStack(alignment: .leading, spacing: 10) {
                                caption("EXPOSED PROPERTIES")
                                ForEach(extraKeys(object), id: \.self) { key in
                                    HStack {
                                        Text(key).font(.caption).lineLimit(1)
                                        Spacer(minLength: 6)
                                        TextField("0", value: numericBinding(object, key: key, fallback: 0), format: .number)
                                            .font(.system(.caption, design: .monospaced)).multilineTextAlignment(.trailing)
                                            .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).frame(width: 85)
                                    }
                                }
                                if extraKeys(object).isEmpty { Text("Add numeric controls in the object editor.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            caption("SIZE")
                            HStack {
                                dimensionField("W", object: object, keyPath: \.width)
                                dimensionField("H", object: object, keyPath: \.height)
                            }
                        }
                        if object.kind == "widget" {
                            Button { codeObject = object } label: {
                                Label("Edit object code", systemImage: "chevron.left.forwardslash.chevron.right").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).tint(accent)
                            Text("HTML and JavaScript run inside this object, with no network or device access.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(18)
                }.frame(maxHeight: 550)
                Divider()
                HStack(spacing: 0) {
                    action("Duplicate", icon: "plus.square.on.square") { store.duplicateSelection() }
                    action("Copy", icon: "doc.on.doc") { store.copySelection() }
                    action("Save", icon: "square.stack.3d.up.badge.a") { store.saveToCatalog(object) }
                    action("Delete", icon: "trash", destructive: true) { store.deleteSelection() }
                }.padding(.vertical, 12).padding(.horizontal, 8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click").font(.title2).foregroundStyle(accent)
                    Text("Select an object").font(.subheadline.weight(.medium))
                    Text("Its editable properties appear here.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 38)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.06), radius: 20, y: 7)
        .sheet(item: $codeObject) { object in ObjectCodeEditor(store: store, objectID: object.id) }
        .accessibilityIdentifier("objectInspector")
    }

    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
    private func latest(_ fallback: CanvasObject) -> CanvasObject { store.notebook.objects.first(where: { $0.id == fallback.id }) ?? fallback }
    private func update(_ id: UUID, _ edit: (inout CanvasObject) -> Void) {
        guard var object = store.notebook.objects.first(where: { $0.id == id }) else { return }
        edit(&object)
        store.update(object)
    }
    private func stringBinding(_ object: CanvasObject, _ key: WritableKeyPath<CanvasObject, String>) -> Binding<String> {
        Binding(get: { latest(object)[keyPath: key] }, set: { value in update(object.id) { $0[keyPath: key] = value } })
    }
    private func numericBinding(_ object: CanvasObject, key: String, fallback: Double) -> Binding<Double> {
        Binding(get: { latest(object).properties[key] ?? fallback }, set: { value in
            guard value.isFinite else { return }
            update(object.id) { item in
                item.properties[key] = value
                if item.shape == "triangle", key == "angleA" || key == "angleB" {
                    item.properties["angleC"] = 180 - (item.properties["angleA"] ?? 49) - (item.properties["angleB"] ?? 52)
                }
            }
        })
    }
    private func parameter(_ object: CanvasObject, key: String, label: String, fallback: Double, range: ClosedRange<Double>, integer: Bool = false) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: integer ? "%.0f" : "%.1f", latest(object).properties[key] ?? fallback)).monospacedDigit()
            }.font(.caption)
            Slider(value: numericBinding(object, key: key, fallback: fallback), in: range, step: integer ? 1 : 0.1, onEditingChanged: { editing in
                if editing { store.checkpoint() } else { store.commit() }
            }).tint(accent)
        }
    }
    private func extraKeys(_ object: CanvasObject) -> [String] {
        let standard: Set<String> = ["amplitude", "frequency", "c", "angleA", "angleB", "angleC", "fontSize", "opacity", "fillOpacity", "bold", "card", "strokeWidth", "cornerRadius"]
        return object.properties.keys.filter { object.kind == "widget" || !standard.contains($0) }.sorted()
    }
    private func hasExtraProperties(_ object: CanvasObject) -> Bool { !extraKeys(object).isEmpty }
    private func dimensionField(_ label: String, object: CanvasObject, keyPath: WritableKeyPath<CanvasObject, Double>) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { latest(object)[keyPath: keyPath] }, set: { value in
                guard value.isFinite else { return }
                update(object.id) { $0[keyPath: keyPath] = min(100_000, max(20, value)) }
            }), format: .number.precision(.fractionLength(0)))
                .font(.system(.caption, design: .monospaced)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
        }
    }
    private func action(_ label: String, icon: String, destructive: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 15)); Text(label).font(.system(size: 9)) }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).foregroundStyle(destructive ? Color.red : Color.secondary).accessibilityLabel(label + " object")
    }
}

private struct ObjectCodeEditor: View {
    @ObservedObject var store: NotebookStore
    let objectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CanvasObject()
    @State private var section = "HTML"
    @State private var propertyName = ""
    @State private var validationError = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    Text("Overview").tag("Overview")
                    Text("Properties").tag("Properties")
                    Text("HTML behavior").tag("HTML")
                }.pickerStyle(.segmented).padding()
                if section == "HTML" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Self-contained HTML, CSS and JavaScript").font(.caption.weight(.medium))
                        Text("Read numeric controls with window.canvasProperties. Network requests, native APIs and navigation are blocked.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.code).font(.system(size: 13, design: .monospaced))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .padding(8).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }.padding(.horizontal).padding(.bottom)
                } else if section == "Properties" {
                    Form {
                        Section("Exposed numeric controls") {
                            ForEach(draft.properties.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(key)
                                    Spacer()
                                    TextField("Value", value: Binding(get: { draft.properties[key] ?? 0 }, set: { draft.properties[key] = $0 }), format: .number)
                                        .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(width: 140)
                                    Button { draft.properties.removeValue(forKey: key) } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }.buttonStyle(.borderless)
                                }
                            }
                            HStack {
                                TextField("New property name", text: $propertyName).autocorrectionDisabled().textInputAutocapitalization(.never)
                                Button("Add") {
                                    let name = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !name.isEmpty && name.count <= 64 && draft.properties.count < 128 { draft.properties[name] = 0; propertyName = "" }
                                }.disabled(propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        Section { Text("Changes reload the object. Runtime animation and button state stay inside its current session; save important settings as exposed properties.").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Form {
                        Section("Identity") { TextField("Name", text: $draft.title); LabeledContent("Type", value: "Sandboxed HTML object"); LabeledContent("ID", value: draft.id.uuidString).font(.caption) }
                        Section("Object structure") {
                            Label("Identity and placement", systemImage: "square.dashed")
                            Label("Exposed numeric properties", systemImage: "slider.horizontal.3")
                            Label("HTML, style and behavior", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Section { Text("Objects travel with your notebook and can be saved in your catalog. This prototype runs browser code inside the object; it does not run arbitrary native or server code.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !validationError.isEmpty { Text(validationError).font(.caption).foregroundStyle(.red).padding() }
            }
            .navigationTitle("Object editor").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try NotebookValidation.validate(draft); store.update(draft); dismiss() }
                        catch { validationError = error.localizedDescription }
                    }.fontWeight(.semibold)
                }
            }
            .onAppear { if let object = store.notebook.objects.first(where: { $0.id == objectID }) { draft = object } }
        }.presentationDetents([.large]).frame(minWidth: 500, minHeight: 560)
    }
}
