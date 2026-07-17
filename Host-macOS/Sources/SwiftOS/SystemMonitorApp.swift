import Foundation
import CoreGraphics

/// System Monitor — an htop-like process and performance monitor.
///
/// Layout, top to bottom, all derived from the content rect handed to
/// `draw(_:in:)`:
///   HEADER     ~84px  hostname, OS + kernel release, ticking uptime and load
///                     average, plus the "Quit Process" button and status flashes.
///   CPU        ~110px 120-sample @4Hz total-CPU history (filled area + polyline),
///                     the current total in large text, and 4 per-core bars.
///   MEMORY     ~56px  used/total bar (green base, orange used) + GB text.
///   PROCESSES  rest    sortable, scrollable process table; click selects a row,
///                     "q" or the button kills the selected process's window.
final class SystemMonitorApp: OSApp {
    init() {
        history = [Double](repeating: 0, count: historyCapacity)
    }

    var title: String { "System Monitor" }
    var preferredContentSize: CGSize { CGSize(width: 520, height: 470) }

    // MARK: - Private state

    private enum SortColumn { case pid, name, cpu, mem, stat }
    private var sortColumn: SortColumn = .cpu
    private var sortAscending = false

    private var selectedPID: Int?

    // CPU history: true ring buffer, newest sample appended at the head.
    private let historyCapacity = 120
    private var history: [Double]
    private var historyHead = 0   // index of the oldest sample, once the buffer is full
    private var historyCount = 0
    private var sampleAccumulator: TimeInterval = 0
    private let sampleInterval: TimeInterval = 0.25 // 4 Hz
    private var perCore: [Double] = [0, 0, 0, 0]

    // Process table scrolling (points)
    private var scrollOffset: CGFloat = 0
    private var maxScrollOffset: CGFloat = 0

    // Transient red status flash ("Operation not permitted")
    private var statusMessage: String?
    private var statusExpiry: TimeInterval = 0

    // Layout cache, refreshed every draw() — mouse events are mapped against these.
    private var quitButtonRect: CGRect = .zero
    private var columnHeaderRects: [(SortColumn, CGRect)] = []
    private var rowsViewport: CGRect = .zero
    private var lastDrawnRows: [ProcessInfo] = []

    private let rowHeight: CGFloat = 22
    private let columnHeaderHeight: CGFloat = 24

    // MARK: - OSApp

    func draw(_ surface: Surface, in rect: CGRect) {
        surface.fill(rect, color: .windowBackground)

        let pad: CGFloat = 10
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 84)
        let cpuRect = CGRect(x: rect.minX, y: headerRect.maxY, width: rect.width, height: 110)
        let memRect = CGRect(x: rect.minX, y: cpuRect.maxY, width: rect.width, height: 56)
        let procRect = CGRect(x: rect.minX, y: memRect.maxY, width: rect.width,
                              height: max(0, rect.maxY - memRect.maxY))

        drawHeader(surface, headerRect, pad)
        drawCPU(surface, cpuRect, pad)
        drawMemory(surface, memRect, pad)
        drawProcesses(surface, procRect, pad)

        // Section separators
        for y in [headerRect.maxY, cpuRect.maxY, memRect.maxY] {
            surface.line(from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y),
                         color: .black.withAlpha(0.45), width: 1)
        }
        drawStatusFlash(surface)
    }

    func handle(_ event: OSEvent) {
        switch event {
        case .mouseDown(let p):
            if quitButtonRect.contains(p) { attemptQuit(); return }
            for (column, rect) in columnHeaderRects where rect.contains(p) {
                setSort(column)
                return
            }
            if rowsViewport.contains(p) {
                let index = Int((p.y - rowsViewport.minY + scrollOffset) / rowHeight)
                if lastDrawnRows.indices.contains(index) {
                    selectedPID = lastDrawnRows[index].pid
                }
            }
        case .scrollWheel(let p, _, let deltaY):
            if rowsViewport.contains(p) {
                scrollOffset = min(max(0, scrollOffset - deltaY), maxScrollOffset)
            }
        case .keyDown(let key) where !key.isRepeat:
            if key.characters.lowercased() == "q" { attemptQuit() }
        default:
            break
        }
    }

    func tick(_ dt: TimeInterval) {
        // Sample total CPU at ~4Hz into the ring buffer.
        sampleAccumulator += dt
        while sampleAccumulator >= sampleInterval {
            sampleAccumulator -= sampleInterval
            pushSample(currentTotalCPU())
            jitterCores()
        }
        // Kernel.shared.processes is re-read every frame in draw(); here we only
        // drop the selection if its process vanished (e.g. it was just killed).
        if let pid = selectedPID, !Kernel.shared.processes.contains(where: { $0.pid == pid }) {
            selectedPID = nil
        }
    }

    // MARK: - Header

    private func drawHeader(_ s: Surface, _ r: CGRect, _ pad: CGFloat) {
        let kernel = Kernel.shared
        s.text(kernel.hostname, at: CGPoint(x: r.minX + pad, y: r.minY + 8),
               color: .titleText, scale: 2)
        s.text("\(kernel.osName) \(kernel.osVersion)  \(kernel.kernelRelease)",
               at: CGPoint(x: r.minX + pad, y: r.minY + 40), color: .gray)

        // Uptime (h:mm:ss) + load average
        let t = Int(kernel.uptime)
        let up = String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        let (l1, l5, l15) = kernel.loadAverage
        let load = String(format: "%.2f %.2f %.2f", l1, l5, l15)
        var x = r.minX + pad
        let y = r.minY + 58
        s.text("up ", at: CGPoint(x: x, y: y), color: .darkGray)
        x += s.textSize("up ").width
        s.text(up, at: CGPoint(x: x, y: y), color: .panelText)
        x += s.textSize(up).width
        s.text("   load average: ", at: CGPoint(x: x, y: y), color: .darkGray)
        x += s.textSize("   load average: ").width
        s.text(load, at: CGPoint(x: x, y: y), color: .green)

        // "Quit Process" button — enabled only when the selection owns a window.
        let buttonSize = CGSize(width: 116, height: 24)
        quitButtonRect = CGRect(x: r.maxX - pad - buttonSize.width, y: r.minY + 10,
                                width: buttonSize.width, height: buttonSize.height)
        let enabled = selectedWindow() != nil
        s.fill(quitButtonRect, color: enabled ? .accent : .darkGray.withAlpha(0.3))
        s.stroke(quitButtonRect, color: enabled ? .accent.withAlpha(0.9) : .darkGray.withAlpha(0.6))
        let label = "Quit Process"
        let ts = s.textSize(label)
        s.text(label,
               at: CGPoint(x: quitButtonRect.midX - ts.width / 2,
                           y: quitButtonRect.midY - ts.height / 2),
               color: enabled ? .white : .gray)
    }

    private func drawStatusFlash(_ s: Surface) {
        guard let message = statusMessage else { return }
        let now = Date().timeIntervalSince1970
        if now >= statusExpiry { statusMessage = nil; return }
        let pulse = 0.6 + 0.4 * sin(now * 9)
        let ts = s.textSize(message)
        s.text(message,
               at: CGPoint(x: quitButtonRect.maxX - ts.width, y: quitButtonRect.maxY + 6),
               color: .red.withAlpha(pulse))
    }

    // MARK: - CPU

    private func drawCPU(_ s: Surface, _ r: CGRect, _ pad: CGFloat) {
        let total = currentTotalCPU()
        s.text("CPU", at: CGPoint(x: r.minX + pad, y: r.minY + 8), color: .gray)

        // Right column: current total in large text + 4 per-core bars.
        let colW: CGFloat = 128
        let colX = r.maxX - pad - colW
        s.text(String(format: "%.0f%%", total), at: CGPoint(x: colX, y: r.minY + 12),
               color: .titleText, scale: 2)
        var barY = r.minY + 46
        for core in 0..<4 {
            let barRect = CGRect(x: colX, y: barY, width: colW, height: 9)
            s.fill(barRect, color: .black.withAlpha(0.35))
            let frac = CGFloat(min(100, max(0, perCore[core])) / 100)
            if frac > 0 {
                s.fill(CGRect(x: colX, y: barY, width: colW * frac, height: 9), color: .accent)
            }
            barY += 14
        }

        // History graph: filled area (thin vertical rects) + polyline on top.
        let graphX = r.minX + pad
        let graphY = r.minY + 26
        let graph = CGRect(x: graphX, y: graphY,
                           width: max(10, colX - 14 - graphX),
                           height: max(10, r.height - 26 - 10))
        s.fill(graph, color: .terminalBackground)
        for frac in [0.25, 0.5, 0.75] {
            let y = graph.minY + graph.height * CGFloat(1 - frac)
            s.line(from: CGPoint(x: graph.minX, y: y), to: CGPoint(x: graph.maxX, y: y),
                   color: .white.withAlpha(0.07), width: 1)
        }
        if historyCount > 0 {
            let slot = graph.width / CGFloat(historyCapacity)
            for i in 0..<historyCount {
                let h = CGFloat(sampleAt(i) / 100) * graph.height
                guard h > 0 else { continue }
                s.fill(CGRect(x: graph.minX + CGFloat(i) * slot, y: graph.maxY - h,
                              width: max(1, slot - 0.5), height: h),
                       color: .accent.withAlpha(0.22))
            }
            if historyCount > 1 {
                for i in 1..<historyCount {
                    let p1 = CGPoint(x: graph.minX + (CGFloat(i) - 0.5) * slot,
                                     y: graph.maxY - CGFloat(sampleAt(i - 1) / 100) * graph.height)
                    let p2 = CGPoint(x: graph.minX + (CGFloat(i) + 0.5) * slot,
                                     y: graph.maxY - CGFloat(sampleAt(i) / 100) * graph.height)
                    s.line(from: p1, to: p2, color: .accent, width: 1.5)
                }
            }
        }
        s.stroke(graph, color: .windowBorder)
    }

    // MARK: - Memory

    private func drawMemory(_ s: Surface, _ r: CGRect, _ pad: CGFloat) {
        let kernel = Kernel.shared
        s.text("MEM", at: CGPoint(x: r.minX + pad, y: r.minY + 8), color: .gray)
        let used = kernel.usedMemoryMB
        let total = kernel.totalMemoryMB
        let label = String(format: "%.1f GB / %.1f GB", used / 1024, total / 1024)
        let ts = s.textSize(label)
        s.text(label, at: CGPoint(x: r.maxX - pad - ts.width, y: r.minY + 8), color: .panelText)

        let bar = CGRect(x: r.minX + pad, y: r.minY + 30,
                         width: max(0, r.width - 2 * pad), height: 16)
        s.fill(bar, color: .green.withAlpha(0.28))
        let frac = CGFloat(min(1, max(0, used / total)))
        if frac > 0 {
            s.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height),
                   color: .orange)
        }
        s.stroke(bar, color: .windowBorder)
    }

    // MARK: - Process table

    private func drawProcesses(_ s: Surface, _ r: CGRect, _ pad: CGFloat) {
        guard r.height > 0 else {
            columnHeaderRects = []
            lastDrawnRows = []
            rowsViewport = .zero
            maxScrollOffset = 0
            return
        }
        s.fill(r, color: .terminalBackground)

        let rows = sortedProcesses() // fresh read of Kernel.shared.processes
        let contentH = CGFloat(rows.count) * rowHeight
        let viewportH = max(0, r.height - columnHeaderHeight)
        let needsScroll = contentH > viewportH
        let scrollW: CGFloat = needsScroll ? 8 : 0
        maxScrollOffset = max(0, contentH - viewportH)
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)

        // Column geometry: PID | NAME | %CPU | MEM | STAT (numeric right-aligned).
        let pidW: CGFloat = 46, cpuW: CGFloat = 52, memW: CGFloat = 54, statW: CGFloat = 40
        let gap: CGFloat = 8
        let rightEdge = r.maxX - pad - scrollW
        let statX = rightEdge - statW
        let memX = statX - gap - memW
        let cpuX = memX - gap - cpuW
        let pidX = r.minX + pad
        let nameX = pidX + pidW + gap
        let nameW = max(10, cpuX - gap - nameX)

        // Clickable header row (rects cached for handle()).
        let headerRect = CGRect(x: r.minX, y: r.minY, width: r.width - scrollW,
                                height: columnHeaderHeight)
        s.fill(headerRect, color: .black.withAlpha(0.35))
        columnHeaderRects = [
            (.pid, CGRect(x: pidX, y: r.minY, width: pidW, height: columnHeaderHeight)),
            (.name, CGRect(x: nameX, y: r.minY, width: nameW, height: columnHeaderHeight)),
            (.cpu, CGRect(x: cpuX, y: r.minY, width: cpuW, height: columnHeaderHeight)),
            (.mem, CGRect(x: memX, y: r.minY, width: memW, height: columnHeaderHeight)),
            (.stat, CGRect(x: statX, y: r.minY, width: statW, height: columnHeaderHeight)),
        ]
        let headerY = r.minY + (columnHeaderHeight - s.textSize("PID").height) / 2
        drawColumnHeader(s, "PID", column: .pid, x: pidX, w: pidW, y: headerY, alignRight: true)
        drawColumnHeader(s, "NAME", column: .name, x: nameX, w: nameW, y: headerY, alignRight: false)
        drawColumnHeader(s, "%CPU", column: .cpu, x: cpuX, w: cpuW, y: headerY, alignRight: true)
        drawColumnHeader(s, "MEM", column: .mem, x: memX, w: memW, y: headerY, alignRight: true)
        drawColumnHeader(s, "STAT", column: .stat, x: statX, w: statW, y: headerY, alignRight: false)

        // Rows (zebra-striped, clipped to the viewport)
        rowsViewport = CGRect(x: r.minX, y: r.minY + columnHeaderHeight,
                              width: r.width - scrollW, height: viewportH)
        lastDrawnRows = rows
        let lineH = s.textSize("Mg").height
        s.pushClip(rowsViewport)
        var i = max(0, Int(scrollOffset / rowHeight))
        while i < rows.count {
            let rowY = rowsViewport.minY + CGFloat(i) * rowHeight - scrollOffset
            if rowY >= rowsViewport.maxY { break }
            let p = rows[i]
            let selected = p.pid == selectedPID
            let rowRect = CGRect(x: rowsViewport.minX, y: rowY,
                                 width: rowsViewport.width, height: rowHeight)
            if selected {
                s.fill(rowRect, color: .selection)
            } else if i % 2 == 1 {
                s.fill(rowRect, color: .white.withAlpha(0.03))
            }
            let ty = rowY + (rowHeight - lineH) / 2
            let base: Color = selected ? .white : .panelText

            let pidS = String(p.pid)
            s.text(pidS, at: CGPoint(x: pidX + pidW - s.textSize(pidS).width, y: ty),
                   color: selected ? .white : .gray)
            s.text(fit(s, p.name, nameW), at: CGPoint(x: nameX, y: ty), color: base)

            let cpuS = String(format: "%.1f", p.cpuPercent)
            s.text(cpuS, at: CGPoint(x: cpuX + cpuW - s.textSize(cpuS).width, y: ty),
                   color: percentColor(p.cpuPercent))

            let memS = String(format: "%.0f", p.memoryMB)
            s.text(memS, at: CGPoint(x: memX + memW - s.textSize(memS).width, y: ty),
                   color: base)

            s.text(p.state, at: CGPoint(x: statX, y: ty),
                   color: p.state == "R" ? .green : .darkGray)
            i += 1
        }
        s.popClip()

        // Thin scrollbar
        if needsScroll {
            let track = CGRect(x: r.maxX - 5, y: rowsViewport.minY, width: 3, height: viewportH)
            s.fill(track, color: .white.withAlpha(0.06))
            let thumbH = max(18, viewportH * (viewportH / contentH))
            let travel = max(0, viewportH - thumbH)
            let thumbY = rowsViewport.minY
                + (maxScrollOffset > 0 ? scrollOffset / maxScrollOffset : 0) * travel
            s.fill(CGRect(x: track.minX, y: thumbY, width: 3, height: thumbH), color: .darkGray)
        }
    }

    private func drawColumnHeader(_ s: Surface, _ title: String, column: SortColumn,
                                  x: CGFloat, w: CGFloat, y: CGFloat, alignRight: Bool) {
        var label = title
        if column == sortColumn { label += sortAscending ? " ^" : " v" }
        label = fit(s, label, w)
        let tx = alignRight ? x + w - s.textSize(label).width : x
        s.text(label, at: CGPoint(x: tx, y: y),
               color: column == sortColumn ? .panelText : .gray)
    }

    // MARK: - Sorting, selection, quitting

    private func sortedProcesses() -> [ProcessInfo] {
        Kernel.shared.processes.sorted { a, b in
            if primaryEqual(a, b) { return a.pid < b.pid }
            let less: Bool
            switch sortColumn {
            case .pid: less = a.pid < b.pid
            case .name: less = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .cpu: less = a.cpuPercent < b.cpuPercent
            case .mem: less = a.memoryMB < b.memoryMB
            case .stat: less = a.state < b.state
            }
            return sortAscending ? less : !less
        }
    }

    private func primaryEqual(_ a: ProcessInfo, _ b: ProcessInfo) -> Bool {
        switch sortColumn {
        case .pid: return a.pid == b.pid
        case .name: return a.name == b.name
        case .cpu: return a.cpuPercent == b.cpuPercent
        case .mem: return a.memoryMB == b.memoryMB
        case .stat: return a.state == b.state
        }
    }

    private func setSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            switch column {
            case .pid, .name, .stat: sortAscending = true
            case .cpu, .mem: sortAscending = false
            }
        }
    }

    /// The selected process is killable only when it backs a real window.
    private func selectedWindow() -> OSWindow? {
        guard let pid = selectedPID else { return nil }
        return WindowManager.shared.windows.first { $0.processPID == pid }
    }

    private func attemptQuit() {
        guard selectedPID != nil else { return }
        if let window = selectedWindow() {
            WindowManager.shared.close(window) // also unregisters the process
            selectedPID = nil
        } else {
            // Daemons / kernel threads have no window: flash EPERM.
            statusMessage = "Operation not permitted"
            statusExpiry = Date().timeIntervalSince1970 + 2.5
        }
    }

    // MARK: - Sampling

    private func currentTotalCPU() -> Double {
        min(100, Kernel.shared.processes.reduce(0) { $0 + $1.cpuPercent })
    }

    private func pushSample(_ value: Double) {
        if historyCount < historyCapacity {
            history[(historyHead + historyCount) % historyCapacity] = value
            historyCount += 1
        } else {
            history[historyHead] = value
            historyHead = (historyHead + 1) % historyCapacity
        }
    }

    /// Oldest-first access into the ring buffer; `index` must be < historyCount.
    private func sampleAt(_ index: Int) -> Double {
        history[(historyHead + index) % historyCapacity]
    }

    /// Split the sampled total across 4 fake cores with jitter + smoothing.
    private func jitterCores() {
        let total = historyCount > 0 ? sampleAt(historyCount - 1) : 0
        let weights = (0..<4).map { _ in Double.random(in: 0.5...1.5) }
        let sum = weights.reduce(0, +)
        for i in 0..<4 {
            let target = min(100, max(0, total * (weights[i] / sum) * 4 + Double.random(in: -2...2)))
            perCore[i] = perCore[i] * 0.45 + target * 0.55
        }
    }

    // MARK: - Formatting helpers

    private func percentColor(_ value: Double) -> Color {
        if value < 5 { return .green }
        if value < 15 { return .yellow }
        return .red
    }

    /// Truncate `string` (monospace) so it fits `width`, marking truncation with ".".
    private func fit(_ s: Surface, _ string: String, _ width: CGFloat) -> String {
        guard s.textSize(string).width > width else { return string }
        let charW = max(1, s.textSize("M").width)
        let maxChars = Int(width / charW)
        if maxChars <= 1 { return String(string.prefix(max(0, maxChars))) }
        return String(string.prefix(maxChars - 1)) + "."
    }
}
