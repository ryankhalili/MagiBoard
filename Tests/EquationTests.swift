import XCTest
import UIKit
@testable import CanvasStudio

@MainActor
final class EquationTests: XCTestCase {
    func testNestedFractionsAndScriptsRemainStructural() throws {
        let parsed = try EquationParser.parse(#"\frac{1}{x_{n+1}^{2}}"#)
        guard case .row(let row) = parsed, row.count == 1,
              case .fraction(_, let denominator, true) = row[0],
              case .row(let denominatorRow) = denominator,
              case .scripts(_, let lower, let upper) = denominatorRow.first else {
            return XCTFail("Fractions and scripts must retain nested math structure")
        }
        XCTAssertNotNil(lower); XCTAssertNotNil(upper)
        let layout = try EquationRenderer.layout(#"\frac{1}{x_{n+1}^{2}}"#, fontSize: 32)
        XCTAssertTrue(layout.width.isFinite && layout.ascent.isFinite && layout.descent.isFinite)
        XCTAssertGreaterThan(layout.size.height, 32)
    }
    func testFractionPlacesNumeratorAndDenominatorAcrossRule() throws {
        let layout = try EquationRenderer.layout(#"\frac{a}{b}"#, fontSize: 30)
        let a = try XCTUnwrap(baseline("a", in: layout))
        let b = try XCTUnwrap(baseline("b", in: layout))
        let bar = try XCTUnwrap(layout.primitives.compactMap { item -> CGFloat? in
            if case .line(let start, let end, _) = item, start.y == end.y { return start.y }; return nil
        }.first)
        XCTAssertLessThan(a.y, bar)
        XCTAssertGreaterThan(b.y, bar)
        XCTAssertEqual(a.x, b.x, accuracy: 3)
        XCTAssertFalse(layout.primitives.contains { if case .text(let text, _, _) = $0 { return text.contains("/") }; return false })
    }
    func testSuperscriptAndSubscriptHaveOppositeBaselines() throws {
        let ordinary = try EquationRenderer.layout("x", fontSize: 30)
        let scripted = try EquationRenderer.layout("x_i^2", fontSize: 30)
        XCTAssertLessThan(try XCTUnwrap(baseline("2", in: scripted)).y, 0)
        XCTAssertGreaterThan(try XCTUnwrap(baseline("i", in: scripted)).y, 0)
        XCTAssertGreaterThan(scripted.size.height, ordinary.size.height)
        XCTAssertGreaterThan(scripted.width, ordinary.width)
    }
    func testGreekFunctionsRootsAndLimitsParseWithoutFallback() throws {
        for source in [
            #"\int_{0}^{\infty}e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}"#,
            #"\sum_{n=1}^{\infty}\frac{1}{n^2}=\frac{\pi^2}{6}"#,
            #"\lim_{x\to0}\frac{\sin x}{x}=1"#,
            #"\sqrt[3]{\alpha^2+\beta^2}+\vec{v}\cdot\hat{x}"#,
            #"\left(\frac{a}{b}\right)^2\leq\left|x\right|"#,
            #"\text{for all }x\in\Omega\quad\mathbf{v}=\dot{x}"#
        ] {
            XCTAssertNil(EquationRenderer.diagnostic(source), source)
            let layout = try EquationRenderer.layout(source)
            XCTAssertGreaterThan(layout.width, 0)
            XCTAssertGreaterThan(layout.size.height, 0)
        }
    }
    func testUnknownCommandsAndIncompleteGroupsAreReported() {
        for source in [#"x+\unknown{x}"#, #"\frac{x}{"#, #"\left(x"#, "x^^2", "}x", #"\sqrt"#] {
            XCTAssertThrowsError(try EquationParser.parse(source), source)
        }
        let diagnostic = EquationRenderer.diagnostic(#"x+\unknown{x}"#)
        XCTAssertEqual(diagnostic?.offset, 2)
        XCTAssertTrue(diagnostic?.message.contains("unknown") == true)
    }
    func testParserBoundsDeepAndOversizedInputs() {
        XCTAssertThrowsError(try EquationParser.parse(String(repeating: "\\sqrt", count: 80) + "x"))
        XCTAssertThrowsError(try EquationParser.parse(String(repeating: "{", count: 80) + "x" + String(repeating: "}", count: 80)))
        XCTAssertThrowsError(try EquationParser.parse(String(repeating: "x", count: 8193)))
    }
    func testEquationCanvasDoesNotRenderMetadataTitle() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        func render(_ title: String) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 420, height: 130), format: format).image { output in
                let object = CanvasObject(kind: "latex", title: title, x: 0, y: 0, width: 420, height: 130,
                                          color: "#172534", text: #"E=mc^2"#, properties: ["fontSize": 32])
                ObjectRenderer.shared.draw(object, in: output.cgContext)
            }
        }
        XCTAssertEqual(render("First hidden title").pngData(), render("Completely different metadata").pngData())
    }
    private func baseline(_ text: String, in layout: EquationLayout) -> CGPoint? {
        layout.primitives.compactMap { item in
            if case .text(let value, _, let point) = item, value == text { return point }; return nil
        }.first
    }
}
