import XCTest
import UIKit
@testable import CanvasStudio

final class GraphTests: XCTestCase {
    func testParametersScientificNotationAndFunctionNotation() {
        let expression = PlotExpression("f(x) = a*x^2 + b*x + c")
        XCTAssertNil(expression.error)
        XCTAssertEqual(expression.variables, ["a", "b", "c", "x"])
        XCTAssertEqual(expression.evaluate(x: 2, parameters: ["a": 2, "b": 3, "c": 4]), 18, accuracy: 1e-12)
        XCTAssertEqual(PlotExpression("1e-3*x + 2E+2").evaluate(x: 3), 200.003, accuracy: 1e-12)
        XCTAssertEqual(PlotExpression("2x + 3(x+1)").evaluate(x: 2), 13, accuracy: 1e-12)
        XCTAssertEqual(PlotExpression("log10(100)+log2(8)").evaluate(x: 0), 5, accuracy: 1e-12)
        XCTAssertEqual(PlotExpression("max(-2,x)+min(2,x)").evaluate(x: 3), 5, accuracy: 1e-12)
    }

    func testPowerPrecedenceRightAssociationAndBoundedInvalidInput() {
        for (source, expected) in [("-2^2", -4.0), ("(-2)^2", 4), ("2^-3", 0.125), ("2^3^2", 512), ("-x^2", -9)] {
            XCTAssertEqual(PlotExpression(source).evaluate(x: 3), expected, accuracy: 1e-12, source)
        }
        for source in ["sin(", "1..2", "1e9999", "x=1", "alert(1)", "pow(2)", "2+", String(repeating: "-", count: 200) + "1", String(repeating: "x", count: 3000)] {
            XCTAssertNotNil(PlotExpression(source).error, source)
            XCTAssertTrue(PlotExpression(source).evaluate(x: 1).isNaN, source)
        }
        XCTAssertTrue(PlotExpression("a*x").diagnostic()?.contains("a") == true)
        XCTAssertNil(PlotExpression("a*x").diagnostic(parameters: ["a": 2]))
    }

    func testEmbeddedAndLegacyParametersAreAppliedExactlyOnce() {
        let embedded = GraphPlot(formula: "amplitude*sin(frequency*x)+c+offset", properties: ["amplitude": 2, "frequency": 3, "c": 4, "offset": 5])
        XCTAssertNil(embedded.error)
        XCTAssertEqual(embedded.value(x: .pi / 6), 11, accuracy: 1e-12)
        let polynomial = GraphPlot(formula: "a*x^2+b*x+c", properties: ["a": 2, "b": 3, "c": 4, "offset": 5])
        XCTAssertEqual(polynomial.value(x: 2), 23, accuracy: 1e-12, "c is a coefficient, offset is the additional shift")
        let legacy = GraphPlot(formula: "sin(x)", properties: ["amplitude": 2, "frequency": 3, "c": 4, "offset": 5])
        XCTAssertEqual(legacy.value(x: .pi / 6), 11, accuracy: 1e-12)
        XCTAssertTrue(legacy.displayFormula.contains("9"), "The displayed formula must include the actual shift")
    }

    func testAutomaticRangeFitsQuadraticWhileExplicitAndTinyBoundsArePreserved() {
        let auto = GraphPlot(formula: "x^2", properties: [:])
        XCTAssertNil(auto.error)
        XCTAssertLessThan(auto.yMin, 0); XCTAssertGreaterThan(auto.yMax, 36)
        let explicit = GraphPlot(formula: "x^2", properties: ["xMin": -3, "xMax": 8, "yMin": -2, "yMax": 7])
        XCTAssertEqual(explicit.xMin, -3); XCTAssertEqual(explicit.xMax, 8)
        XCTAssertEqual(explicit.yMin, -2); XCTAssertEqual(explicit.yMax, 7)
        let tiny = GraphPlot(formula: "x^2", properties: ["xMin": -0.00001, "xMax": 0.00001])
        XCTAssertEqual(tiny.xSpan, 0.00002, accuracy: 1e-14)
        XCTAssertGreaterThan(tiny.yMax, 1e-10); XCTAssertLessThan(tiny.yMax, 2e-10)
        let constant = GraphPlot(formula: "5", properties: [:])
        XCTAssertLessThan(constant.yMin, 5); XCTAssertGreaterThan(constant.yMax, 5)
        XCTAssertNotNil(GraphPlot(formula: "x", properties: ["xMin": 2, "xMax": 1]).error)
    }

    func testNiceTicksSupportSmallAndLargeRangesWithDistinctLabels() {
        for (minimum, maximum) in [(-0.002, 0.003), (-6.0, 6.0), (1_000_000.0, 1_800_000.0), (1_000_000.0, 1_000_001.0), (0.0, 1e-10)] {
            let ticks = GraphPlot.ticks(min: minimum, max: maximum)
            let step = GraphPlot.tickStep(min: minimum, max: maximum)
            XCTAssertGreaterThanOrEqual(ticks.count, 3); XCTAssertLessThanOrEqual(ticks.count, 10)
            XCTAssertTrue(ticks.allSatisfy { $0 >= minimum - step * 1e-6 && $0 <= maximum + step * 1e-6 })
            let labels = ticks.map { GraphPlot.tickLabel($0, step: step) }
            XCTAssertEqual(Set(labels).count, labels.count, "Axis labels must remain distinct at \(step)")
        }
        XCTAssertEqual(GraphPlot.tickLabel(-1e-15, step: 0.1), "0")
    }

    func testPolesBreakPathsAndInvalidDomainsHaveVisibleDiagnostic() {
        let reciprocal = GraphPlot(formula: "1/x", properties: ["xMin": -3, "xMax": 3, "yMin": -5, "yMax": 5])
        XCTAssertGreaterThanOrEqual(reciprocal.segments.count, 2)
        for segment in reciprocal.segments {
            let xs = segment.map(\.x)
            XCTAssertFalse((xs.min() ?? 1) < 0.5 && (xs.max() ?? 0) > 0.5, "Do not connect across a pole")
        }
        let missing = GraphPlot(formula: "unknown*x", properties: [:])
        XCTAssertTrue(missing.error?.contains("unknown") == true); XCTAssertTrue(missing.segments.isEmpty)
        let domain = GraphPlot(formula: "sqrt(-abs(x)-1)", properties: [:])
        XCTAssertTrue(domain.error?.contains("No real values") == true)
        let partialDomain = GraphPlot(formula: "sqrt(x)", properties: [:])
        XCTAssertNil(partialDomain.error); XCTAssertFalse(partialDomain.segments.isEmpty)
    }

    @MainActor func testGraphRendererShowsErrorAndAutoRangeWithoutCrashing() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 460, height: 330))
        let valid = CanvasObject(kind: "graph", width: 460, height: 330, text: "a*x^2+b*x+c", properties: ["a": 1, "b": 0, "c": 0])
        let image = renderer.image { ObjectRenderer.shared.draw(valid, in: $0.cgContext) }
        var invalid = valid; invalid.text = "missing*x"
        let errorImage = renderer.image { ObjectRenderer.shared.draw(invalid, in: $0.cgContext) }
        XCTAssertNotEqual(try XCTUnwrap(image.pngData()), try XCTUnwrap(errorImage.pngData()), "Invalid expressions render an explanation instead of the valid curve")
    }
}
