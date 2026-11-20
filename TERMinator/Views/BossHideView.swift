import AppKit
import SwiftUI

/// Puts Boss Hide up or takes it down: the overlay (ContentView shows it while `bossHideActive`) and the window title.
enum BossHide {
    static func set(_ active: Bool) {
        AppState.shared.bossHideActive = active
        applyTitle(active)
        // Publishing bossHideActive re-evaluates the WindowGroup scene, which can put its own title back: set it
        // again once SwiftUI has finished that update.
        DispatchQueue.main.async {
            if AppState.shared.bossHideActive == active {
                applyTitle(active)
            }
        }
    }

    private static func applyTitle(_ active: Bool) {
        if let window = WindowSizeManager.mainWindow {
            window.title = active ? BossHideView.fakeTitle : SessionMode.windowTitle
        }
    }
}

/// The Boss Hide screen: a full-window, perfectly boring spreadsheet (a quarterly budget in a spreadsheet look-alike).
/// Same layout as the Windows and Linux clients. ContentView puts it over everything and swallows keys while it's up;
/// any key hides it again.
struct BossHideView: View {
    static let fakeTitle = "Q3 Budget Forecast.xlsx - Excel"

    private let budget = BossBudget.make()

    fileprivate static let green = rgb(0x21, 0x73, 0x46)
    fileprivate static let darkGreen = rgb(0x1A, 0x5C, 0x38)
    fileprivate static let chrome = rgb(0xF3, 0xF3, 0xF3)
    fileprivate static let chromeText = rgb(0x44, 0x44, 0x44)
    fileprivate static let gridLine = rgb(0xE1, 0xE1, 0xE1)
    fileprivate static let headerLine = rgb(0xC6, 0xC6, 0xC6)
    fileprivate static let cellText = rgb(0x22, 0x22, 0x22)
    fileprivate static let negative = rgb(0xC0, 0x00, 0x00)
    fileprivate static let headerFill = rgb(0xDD, 0xEB, 0xF7)
    fileprivate static let lightText = rgb(0xDD, 0xEE, 0xE4)

    fileprivate static let columnWidths: [CGFloat] = [190, 96, 96, 96, 104, 104, 96, 90, 72, 72, 72, 72, 72, 72]
    fileprivate static let activeRow = 18
    fileprivate static let activeColumn = 4 // E

    var body: some View {
        VStack(spacing: 0) {
            titleBar.frame(height: 32)
            tabs.frame(height: 30)
            ribbon.frame(height: 66)
            formulaBar.frame(height: 30)
            sheet
            sheetTabs.frame(height: 28)
            statusBar.frame(height: 24)
        }
        .background(Color.white)
        .contentShape(Rectangle())
        .onTapGesture {} // clicks land here, not on the app underneath
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: 0) {
            label("AutoSave", 12, .white)
                .padding(.leading, 12)
            ZStack(alignment: .leading) {
                Capsule().stroke(Color.white, lineWidth: 1).frame(width: 30, height: 14)
                Circle().fill(Color.white).frame(width: 8, height: 8).padding(.leading, 3)
            }
            .padding(.leading, 6)
            .padding(.trailing, 18)
            label("Q3 Budget Forecast.xlsx  \u{00B7}  Saved", 12, .white)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Self.darkGreen)
                .frame(width: 320, height: 22)
                .overlay(label("   Search", 12, Self.lightText).frame(maxWidth: .infinity, alignment: .leading))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.green)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            label("File", 13, .white)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .background(Self.green)
            ForEach(["Home", "Insert", "Page Layout", "Formulas", "Data", "Review", "View", "Help"], id: \.self) { name in
                let active = name == "Home"
                label(name, 13, active ? Self.green : Self.chromeText, bold: active)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .overlay(Rectangle().fill(active ? Self.green : .clear).frame(height: 3), alignment: .bottom)
            }
            Spacer()
        }
        .background(Self.chrome)
    }

    private var ribbon: some View {
        let groups: [(String, String, String)] = [
            ("Paste \u{25BE}", "Cut  \u{00B7}  Copy  \u{00B7}  Format Painter", "Clipboard"),
            ("Calibri          \u{25BE}   11 \u{25BE}", "B    I    U \u{25BE}    A \u{25BE}", "Font"),
            ("\u{2261}   \u{2261}   \u{2261}      Wrap Text", "Merge & Center \u{25BE}", "Alignment"),
            ("Currency            \u{25BE}", "$ \u{25BE}    %    ,    .0   .00", "Number"),
            ("Conditional Formatting \u{25BE}", "Format as Table \u{25BE}   Cell Styles \u{25BE}", "Styles"),
            ("Insert \u{25BE}   Delete \u{25BE}", "Format \u{25BE}", "Cells"),
            ("\u{03A3} AutoSum \u{25BE}    Sort & Filter \u{25BE}", "Fill \u{25BE}    Clear \u{25BE}    Find & Select \u{25BE}", "Editing")
        ]
        return HStack(spacing: 0) {
            ForEach(0..<groups.count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    label(groups[index].0, 12, Self.cellText)
                    label(groups[index].1, 12, Self.cellText)
                    label(groups[index].2, 11, Self.chromeText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                Rectangle().fill(Self.headerLine).frame(width: 1).padding(.vertical, 8)
            }
            Spacer()
        }
        .background(Self.chrome)
    }

    private var formulaBar: some View {
        HStack(spacing: 0) {
            label("  E18", 12, Self.cellText)
                .frame(width: 90, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(Rectangle().fill(Self.headerLine).frame(width: 1), alignment: .trailing)
            label("\u{2715}    \u{2713}    fx", 12, Self.chromeText)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .overlay(Rectangle().fill(Self.headerLine).frame(width: 1), alignment: .trailing)
            label("=SUM(E5:E16)", 13, Self.cellText)
                .padding(.leading, 8)
            Spacer()
        }
        .overlay(Rectangle().fill(Self.headerLine).frame(height: 1), alignment: .bottom)
        .background(Color.white)
    }

    private var sheetTabs: some View {
        HStack(spacing: 0) {
            label("\u{25C0}   \u{25B6}", 11, Self.chromeText)
                .padding(.leading, 12)
                .padding(.trailing, 16)
            ForEach(["Summary", "Q3 Detail", "Assumptions"], id: \.self) { name in
                let active = name == "Q3 Detail"
                label(name, 12, active ? Self.green : Self.chromeText, bold: active)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                    .background(active ? Color.white : Self.chrome)
                    .overlay(Rectangle().fill(active ? Self.green : Self.headerLine)
                        .frame(width: active ? nil : 1, height: active ? 3 : nil),
                             alignment: active ? .bottom : .trailing)
            }
            label("+", 15, Self.chromeText)
                .padding(.horizontal, 12)
            Spacer()
        }
        .background(Self.chrome)
    }

    private var statusBar: some View {
        HStack {
            label("Ready", 12, Self.chromeText)
                .padding(.leading, 12)
            Spacer()
            label("Sum: \(BossBudget.money(budget.activeValue))            \u{25A6}   \u{25A4}   \u{25A5}       "
                + "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{25CF}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}   100%",
                  12, Self.chromeText)
                .padding(.trailing, 14)
        }
        .frame(maxHeight: .infinity)
        .background(Self.chrome)
    }

    // MARK: - Sheet

    private var sheet: some View {
        let cells = budget.cells
        return Canvas { context, size in
            let rowHeaderWidth: CGFloat = 44
            let headerHeight: CGFloat = 22
            let rowHeight: CGFloat = 21

            // Column edges: row header, then A, B, C...
            var edges: [CGFloat] = [0, rowHeaderWidth]
            for width in Self.columnWidths {
                edges.append(edges[edges.count - 1] + width)
            }
            func rowTop(_ row: Int) -> CGFloat { headerHeight + CGFloat(row - 1) * rowHeight }

            // Cell fills
            for cell in cells where cell.fill {
                let rect = CGRect(x: edges[cell.col + 1], y: rowTop(cell.row),
                                  width: Self.columnWidths[cell.col], height: rowHeight)
                context.fill(Path(rect), with: .color(Self.headerFill))
            }

            // Header backgrounds
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: headerHeight)), with: .color(Self.chrome))
            context.fill(Path(CGRect(x: 0, y: 0, width: rowHeaderWidth, height: size.height)), with: .color(Self.chrome))

            // Grid lines
            var grid = Path()
            for x in edges.dropFirst() {
                grid.move(to: CGPoint(x: x + 0.5, y: 0))
                grid.addLine(to: CGPoint(x: x + 0.5, y: size.height))
            }
            var y = headerHeight
            while y < size.height {
                grid.move(to: CGPoint(x: 0, y: y + 0.5))
                grid.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                y += rowHeight
            }
            context.stroke(grid, with: .color(Self.gridLine), lineWidth: 1)

            // Column letters and row numbers
            for column in 0..<Self.columnWidths.count {
                let letter = String(UnicodeScalar(UInt8(65 + column)))
                context.draw(Text(letter).font(.system(size: 12)).foregroundColor(Self.chromeText),
                             at: CGPoint(x: (edges[column + 1] + edges[column + 2]) / 2, y: headerHeight / 2))
            }
            var row = 1
            while rowTop(row) < size.height {
                context.draw(Text("\(row)").font(.system(size: 12)).foregroundColor(Self.chromeText),
                             at: CGPoint(x: rowHeaderWidth / 2, y: rowTop(row) + rowHeight / 2))
                row += 1
            }

            // Cell text, spanning to the right where it runs long
            for cell in cells where !cell.text.isEmpty {
                let midY = rowTop(cell.row) + rowHeight / 2
                let text = Text(cell.text)
                    .font(.system(size: cell.size, weight: cell.bold ? .bold : .regular))
                    .foregroundColor(cell.color ?? Self.cellText)
                if cell.right {
                    context.draw(text, at: CGPoint(x: edges[cell.col + 2] - 5, y: midY), anchor: .trailing)
                } else {
                    context.draw(text, at: CGPoint(x: edges[cell.col + 1] + 5, y: midY), anchor: .leading)
                }
            }

            // The active cell
            let active = CGRect(x: edges[Self.activeColumn + 1], y: rowTop(Self.activeRow),
                                width: Self.columnWidths[Self.activeColumn], height: rowHeight)
            context.stroke(Path(active), with: .color(Self.green), lineWidth: 2)
        }
        .clipped()
    }

    private func label(_ text: String, _ size: CGFloat, _ color: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: size, weight: bold ? .semibold : .regular))
            .foregroundColor(color)
            .lineLimit(1)
    }
}

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}

private struct BossCell {
    let row: Int
    let col: Int
    let text: String
    var right = false
    var bold = false
    var color: Color? = nil
    var fill = false
    var size: CGFloat = 14.5
}

/// The dull numbers. Seeded, so the same budget comes up every time (not the same figures as the .NET clients, whose
/// Random can't be reproduced here — nobody will be checking the sums).
private enum BossBudget {
    static func make() -> (cells: [BossCell], activeValue: Int) {
        var cells: [BossCell] = [
            BossCell(row: 1, col: 0, text: "Q3 Budget Forecast \u{2014} FY2026", bold: true, size: 20),
            BossCell(row: 2, col: 0, text: "Cost center 4410 \u{00B7} Operations \u{00B7} All figures USD", color: BossHideView.chromeText)
        ]

        let headers = ["Department", "July", "August", "September", "Q3 Total", "Budget", "Variance", "% of Budget"]
        for (column, header) in headers.enumerated() {
            cells.append(BossCell(row: 4, col: column, text: header, right: column > 0, bold: true, fill: true))
        }

        let departments = ["Facilities", "IT Infrastructure", "Software Licenses", "Telecom", "Travel & Expenses",
                           "Training", "Contractors", "Marketing Programs", "Office Supplies", "Insurance",
                           "Legal & Compliance", "Equipment Leases"]

        var seed: UInt64 = 4410
        func nextUnit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }

        var monthTotals = [0, 0, 0]
        var quarterTotal = 0, budgetTotal = 0
        for (index, department) in departments.enumerated() {
            let row = 5 + index
            let base = (4 + Int(nextUnit() * 56)) * 1000 + Int(nextUnit() * 1000)
            var quarter = 0
            cells.append(BossCell(row: row, col: 0, text: department))
            for month in 0..<3 {
                let amount = Int(Double(base) * (0.85 + nextUnit() * 0.3))
                monthTotals[month] += amount
                quarter += amount
                cells.append(BossCell(row: row, col: 1 + month, text: money(amount), right: true))
            }
            let budget = Int((Double(quarter) * (0.92 + nextUnit() * 0.16) / 100).rounded()) * 100
            cells.append(contentsOf: totals(row: row, total: quarter, budget: budget, bold: false))
            quarterTotal += quarter
            budgetTotal += budget
        }

        let totalRow = 5 + departments.count + 1
        cells.append(BossCell(row: totalRow, col: 0, text: "Total", bold: true))
        for month in 0..<3 {
            cells.append(BossCell(row: totalRow, col: 1 + month, text: money(monthTotals[month]), right: true, bold: true))
        }
        cells.append(contentsOf: totals(row: totalRow, total: quarterTotal, budget: budgetTotal, bold: true))

        cells.append(BossCell(row: totalRow + 2, col: 0, text: "Notes", bold: true))
        cells.append(BossCell(row: totalRow + 3, col: 0,
                              text: "Travel freeze extended through the end of the quarter per the CFO memo.",
                              color: BossHideView.chromeText))
        cells.append(BossCell(row: totalRow + 4, col: 0,
                              text: "Reforecast is due to Finance by the 15th. Any variance over 5% needs a comment.",
                              color: BossHideView.chromeText))

        return (cells, quarterTotal)
    }

    private static func totals(row: Int, total: Int, budget: Int, bold: Bool) -> [BossCell] {
        let variance = budget - total
        return [
            BossCell(row: row, col: 4, text: money(total), right: true, bold: bold),
            BossCell(row: row, col: 5, text: money(budget), right: true, bold: bold),
            BossCell(row: row, col: 6, text: variance < 0 ? "(\(money(-variance)))" : money(variance), right: true,
                     bold: bold, color: variance < 0 ? BossHideView.negative : nil),
            BossCell(row: row, col: 7, text: String(format: "%.1f%%", Double(total) * 100 / Double(max(budget, 1))),
                     right: true, bold: bold)
        ]
    }

    static func money(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return "$" + (formatter.string(from: NSNumber(value: amount)) ?? "\(amount)")
    }
}
