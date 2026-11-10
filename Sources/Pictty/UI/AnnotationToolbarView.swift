// The annotation bar: shown only while annotating, where the crop bar shows while cropping. Tools,
// smart redact, colour, width, fill, shadow, Undo and Redo, and Done.

import PicttyCore
import SwiftUI

struct AnnotationToolbarView: View {
    @ObservedObject var model: ViewerModel
    let controller: ViewerWindowController

    private static let tools: [(Annotation.Kind?, String, String)] = [
        (nil, "cursorarrow", "Select and move (V)"),
        (.arrow, "arrow.up.right", "Arrow (A) · drag its middle to curve it"),
        (.rectangle, "rectangle", "Rectangle (R) · ⇧ for a square"),
        (.roundedRectangle, "app", "Rounded rectangle (U)"),
        (.ellipse, "circle", "Circle (O) · ⇧ for a round one"),
        (.text, "textformat", "Text (T)"),
        (.step, "1.circle", "Steps (N) · ① ② ③, renumbered on delete"),
        (.highlighter, "highlighter", "Highlighter (H)"),
        (.blur, "drop", "Blur (B)"),
        (.censor, "square.grid.3x3.fill", "Censor (X)"),
        (.magnifier, "plus.magnifyingglass", "Magnifier (M) · drag over a detail"),
        (.spotlight, "flashlight.on.fill", "Spotlight (S) · dims everything else"),
    ]

    var body: some View {
        if model.annotating { bar }
    }

    private var bar: some View {
        HStack(spacing: 3) {
            ForEach(Self.tools.indices, id: \.self) { i in
                let (kind, symbol, help) = Self.tools[i]
                GlyphButton(symbol: symbol, help: help, isOn: model.annotationTool == kind) {
                    controller.setAnnotationTool(kind)
                }
            }
            if model.annotationTool == .censor {
                GlyphButton(symbol: model.censorSolid ? "rectangle.fill" : "square.grid.3x3",
                            help: model.censorSolid ? "Censor: a solid bar · click for pixels" : "Censor: pixels · click for a solid bar",
                            isOn: model.censorSolid) { model.censorSolid.toggle() }
            }
            separator
            GlyphButton(symbol: "wand.and.stars", help: "Smart redact: hide e-mails, phone and card numbers, and faces") {
                controller.smartRedact()
            }
            separator
            colours
            separator
            ForEach(AnnotationStyle.Width.allCases, id: \.self) { w in
                Button { controller.setAnnotationStyle { $0.width = w } } label: {
                    Circle().fill(.white.opacity(model.annotationStyle.width == w ? 0.95 : 0.55))
                        .frame(width: [4.0, 7.0, 11.0][w.rawValue], height: [4.0, 7.0, 11.0][w.rawValue])
                        .frame(width: 22, height: 25)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(model.annotationStyle.width == w ? 0.16 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(["Thin", "Regular", "Thick"][w.rawValue]))
            }
            GlyphButton(symbol: model.annotationStyle.filled ? "square.fill" : "square", help: "Fill shapes",
                        isOn: model.annotationStyle.filled) { controller.setAnnotationStyle { $0.filled.toggle() } }
            GlyphButton(symbol: "shadow", help: "Shadow", isOn: model.annotationStyle.shadow) {
                controller.setAnnotationStyle { $0.shadow.toggle() }
            }
            separator
            GlyphButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { controller.undoAnnotation() }
                .disabled(!controller.canUndoAnnotation).opacity(controller.canUndoAnnotation ? 1 : 0.35)
            GlyphButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { controller.redoAnnotation() }
                .disabled(!controller.canRedoAnnotation).opacity(controller.canRedoAnnotation ? 1 : 0.35)
            separator
            Button { controller.finishAnnotating() } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0x34A8F0), Color(hex: 0x4285F4)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .foregroundStyle(.white)
                    .shadow(color: Color(hex: 0x4285F4).opacity(0.5), radius: 6)
            }
            .buttonStyle(.plain)
            .help(L("Return"))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .liquidGlassCapsule(tint: 0.5, shadow: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Auto, the six colours, and any other.
    private var colours: some View {
        HStack(spacing: 4) {
            Button { controller.setAnnotationColour(nil) } label: {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center)).opacity(0.85))
                    .overlay(Circle().stroke(.white, lineWidth: model.autoColour ? 2 : 0))
            }
            .buttonStyle(.plain)
            .help(L("Auto: the colour that stands out against the picture"))
            ForEach(AnnotationStyle.palette.indices, id: \.self) { i in
                let c = AnnotationStyle.palette[i]
                Button { controller.setAnnotationColour(c) } label: {
                    Circle().fill(Color(cgColor: c.cgColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))
                        .overlay(Circle().stroke(.white, lineWidth: !model.autoColour && model.annotationStyle.colour == c ? 2 : 0).padding(-2.5))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(get: { Color(cgColor: model.annotationStyle.colour.cgColor) }, set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                controller.setAnnotationColour(.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 26)
            .help(L("Another colour"))
        }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}
