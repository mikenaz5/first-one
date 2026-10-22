import SwiftUI
import UIKit

/// What someone is in the middle of signing: a typed or drawn signature, and the name that goes with it.
@MainActor
@Observable
final class SignatureCapture {
    /// Only `.typed` and `.drawn` can be chosen by a person.
    var method: SignatureMethod = .typed
    var fullName: String
    var strokes: [[CGPoint]] = []
    /// Size of the drawing area, so the exported image matches what was drawn.
    var canvasSize: CGSize = .zero

    private var isDrawing = false

    init(fullName: String = "") {
        self.fullName = fullName
    }

    var trimmedName: String { fullName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasInk: Bool { strokes.contains { $0.count > 1 } }

    /// Ready to sign: a real name, and ink if they chose to draw.
    var isReady: Bool {
        guard SignatureRules.nameLength.contains(trimmedName.count) else { return false }
        return method == .typed || hasInk
    }

    // MARK: Drawing

    func extendStroke(to point: CGPoint) {
        if isDrawing, !strokes.isEmpty {
            strokes[strokes.count - 1].append(point)
        } else {
            strokes.append([point])
            isDrawing = true
        }
    }

    func endStroke() { isDrawing = false }

    func clear() {
        strokes = []
        isDrawing = false
    }

    // MARK: Output

    /// The drawn signature as a transparent PNG, or nil if there's nothing drawn.
    func pngData() -> Data? {
        guard hasInk, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let ink = UIColor(Color.slateInk)
        return renderer.pngData { _ in
            ink.setStroke()
            for stroke in strokes where stroke.count > 1 {
                let path = UIBezierPath()
                path.lineWidth = 2.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke[0])
                for index in 1..<stroke.count {
                    // Smooth the line by curving through the midpoints.
                    let mid = CGPoint(x: (stroke[index - 1].x + stroke[index].x) / 2, y: (stroke[index - 1].y + stroke[index].y) / 2)
                    path.addQuadCurve(to: mid, controlPoint: stroke[index - 1])
                }
                path.addLine(to: stroke[stroke.count - 1])
                path.stroke()
            }
        }
    }

    func input(documentHash: String) -> SignatureInput {
        SignatureInput(
            documentHash: documentHash,
            signedName: trimmedName,
            method: method,
            imagePNG: method == .drawn ? pngData() : nil
        )
    }

    func creatorSignature() -> CreatorSignature {
        CreatorSignature(
            signedName: trimmedName,
            method: method,
            imagePNG: method == .drawn ? pngData() : nil,
            updatedAt: Date()
        )
    }
}

// MARK: - Views

/// Type-or-draw signature entry with a consent line. Typing is the default, and always available
/// as an alternative to drawing.
struct SignatureSection: View {
    @Bindable var capture: SignatureCapture
    let consent: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Picker("Signature type", selection: $capture.method) {
                Text("Type").tag(SignatureMethod.typed)
                Text("Draw").tag(SignatureMethod.drawn)
            }
            .pickerStyle(.segmented)

            TextField("Full name", text: $capture.fullName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .frame(minHeight: Metrics.minTapTarget)
                .padding(.horizontal, Space.l)
                .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .accessibilityLabel("Your full name")

            switch capture.method {
            case .typed, .onFile:
                TypedSignaturePreview(name: capture.trimmedName)
            case .drawn:
                SignaturePad(capture: capture)
            }

            Text(consent)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .motionSafe(.slateSnappy, value: capture.method)
    }
}

struct TypedSignaturePreview: View {
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Text(name.isEmpty ? "Your signature" : name)
                .font(.custom("SnellRoundhand-Bold", size: 38, relativeTo: .largeTitle))
                .foregroundStyle(name.isEmpty ? Color.slateInk.opacity(0.35) : Color.slateInk)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.m)
                .frame(maxWidth: .infinity, minHeight: Metrics.signaturePreviewMinHeight, alignment: .bottomLeading)
            Rectangle().fill(Color.slateInk.opacity(0.25)).frame(height: 1).padding(.horizontal, Space.l).padding(.bottom, Space.s)
        }
        .background(Color.slatePaper, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.isEmpty ? "Typed signature, empty" : "Typed signature: \(name)")
    }
}

struct SignaturePad: View {
    @Bindable var capture: SignatureCapture

    var body: some View {
        // Read the strokes here, in the body, so every new point redraws the canvas.
        let strokes = capture.strokes

        VStack(alignment: .trailing, spacing: Space.xs) {
            ZStack(alignment: .bottomLeading) {
                Canvas { context, _ in
                    for stroke in strokes where stroke.count > 1 {
                        var path = Path()
                        path.move(to: stroke[0])
                        for index in 1..<stroke.count {
                            let mid = CGPoint(x: (stroke[index - 1].x + stroke[index].x) / 2, y: (stroke[index - 1].y + stroke[index].y) / 2)
                            path.addQuadCurve(to: mid, control: stroke[index - 1])
                        }
                        path.addLine(to: stroke[stroke.count - 1])
                        context.stroke(path, with: .color(Color.slateInk), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { capture.extendStroke(to: $0.location) }
                        .onEnded { _ in capture.endStroke() }
                )

                if !capture.hasInk {
                    Text("Sign here with your finger")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateInk.opacity(0.35))
                        .padding(Space.l)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(Color.slateInk.opacity(0.25)).frame(height: 1).padding(.horizontal, Space.l).padding(.bottom, Space.l).allowsHitTesting(false)
            }
            .frame(height: Metrics.signaturePadHeight)
            .background(Color.slatePaper, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { capture.canvasSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in capture.canvasSize = size }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(capture.hasInk ? "Signature drawn" : "Signature pad, empty")
            .accessibilityHint("Draw with your finger, or switch to Type to type your name instead")

            Button("Clear", systemImage: "arrow.counterclockwise") { capture.clear() }
                .font(.subheadline)
                .frame(minHeight: Metrics.minTapTarget)
                .disabled(!capture.hasInk)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: capture.strokes.count)
    }
}
