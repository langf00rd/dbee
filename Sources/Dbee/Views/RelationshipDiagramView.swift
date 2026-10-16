import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The tables of one schema as boxes, with a line for every foreign key between them.
///
/// Tables can be dragged around; clicking one highlights its relations, double-clicking opens it.
/// Lines use crow's foot notation: the fork is at the referencing table (many), the bar at the
/// referenced table (one), with a circle there when the reference is optional (nullable columns).
struct RelationshipDiagramView: View {
    @Bindable var model: RelationshipDiagramModel
    let session: DatabaseSession

    @State private var viewport: CGSize = .zero
    @State private var zoomAtGestureStart: CGFloat?

    static let zoomRange: ClosedRange<CGFloat> = 0.2...2

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasLoaded, !model.tables.isEmpty {
                Divider()
                footer
            }
        }
        .task(id: model.schema) { await model.loadIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if session.schemas.count > 1 {
                schemaPicker
            }
            Spacer()
            Picker("Columns", selection: $model.keysOnly) {
                Text("All Columns").tag(false)
                Text("Keys Only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show every column, or only primary and foreign key columns")
            Spacer()
            zoomControls
            Divider()
                .frame(height: 16)
            HStack(spacing: 4) {
                Button {
                    model.arrange()
                } label: {
                    Label("Arrange Tables", systemImage: "rectangle.3.group")
                }
                .help("Lay out all tables again")
                Button(action: exportImage) {
                    Label("Export as Image", systemImage: "square.and.arrow.up")
                }
                .help("Export the diagram as a PNG image")
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Refresh Diagram", systemImage: "arrow.clockwise")
                }
                .help("Read the tables and foreign keys again")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.tables.isEmpty || model.isLoading)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var schemaPicker: some View {
        Menu {
            ForEach(session.schemas) { schema in
                Toggle(isOn: Binding(
                    get: { schema.name == model.schema },
                    set: { if $0 { session.showDiagram(schema: schema.name) } }
                )) {
                    Text(schema.name)
                }
            }
        } label: {
            Text(model.schema)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Schema")
        .accessibilityLabel("Schema")
        .accessibilityValue(model.schema)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                setZoom(model.zoom / 1.25)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom Out (⌘-)")
            Button {
                fitToWindow()
            } label: {
                Text(model.zoom, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .help("Zoom to Fit")
            .accessibilityLabel("Zoom to Fit")
            Button {
                setZoom(model.zoom * 1.25)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help("Zoom In (⌘+)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(model.tables.isEmpty)
    }

    private func setZoom(_ zoom: CGFloat) {
        model.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func fitToWindow() {
        let size = model.canvasSize
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        setZoom(min(viewport.width / size.width, viewport.height / size.height, 1))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.hasLoaded {
            if model.tables.isEmpty {
                ContentUnavailableView("No Tables", systemImage: "tablecells",
                                       description: Text("“\(model.schema)” has no tables to draw."))
            } else {
                diagram
            }
        } else if let message = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn’t Load the Diagram", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        } else {
            ProgressView()
                .accessibilityLabel("Loading diagram")
        }
    }

    private var diagram: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                let size = model.canvasSize
                DiagramCanvas(model: model, interactive: true, onOpen: open)
                    .scaleEffect(model.zoom, anchor: .topLeading)
                    .frame(width: size.width * model.zoom, height: size.height * model.zoom, alignment: .topLeading)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedTable = nil }
            }
            .background(DiagramCanvas.background)
            .onAppear { viewport = proxy.size }
            .onChange(of: proxy.size) { _, size in viewport = size }
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? model.zoom
                    zoomAtGestureStart = start
                    setZoom(start * value.magnification)
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.tables.count.formatted()) table\(model.tables.count == 1 ? "" : "s"), \(model.relations.count.formatted()) relationship\(model.relations.count == 1 ? "" : "s")")
            if model.externalReferenceCount > 0 {
                Text("\(model.externalReferenceCount.formatted()) to other schemas not shown")
                    .help("Foreign keys that reference tables in other schemas")
            }
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            } else if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(1)
                    .help(message)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func open(_ table: DiagramTable) {
        session.selection = .table(table.ref)
    }

    // MARK: Export

    private func exportImage() {
        let panel = NSSavePanel()
        panel.title = "Export Diagram"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]
        let name = model.schema.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = (name.isEmpty ? "Diagram" : name + " diagram") + ".png"

        let window = NSApp.keyWindow
        let model = model
        let colorScheme: ColorScheme = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try Self.writeImage(of: model, colorScheme: colorScheme, to: url)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "The diagram couldn't be exported."
                    alert.informativeText = error.localizedDescription
                    if let window, window.isVisible {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// Renders the whole diagram at full size (twice that when it fits), unselected, in `colorScheme`.
    @MainActor static func writeImage(of model: RelationshipDiagramModel, colorScheme: ColorScheme, to url: URL) throws {
        let size = model.canvasSize
        let selected = model.selectedTable
        model.selectedTable = nil
        defer { model.selectedTable = selected }
        let renderer = ImageRenderer(content:
            DiagramCanvas(model: model, interactive: false, onOpen: { _ in })
                .background(DiagramCanvas.background)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = min(2, 16_000 / max(size.width, size.height, 1))
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DatabaseError("The diagram couldn't be drawn.")
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Canvas

/// The diagram at 100%: relationship lines underneath, table boxes on top.
private struct DiagramCanvas: View {
    let model: RelationshipDiagramModel
    /// Off for image export: no gestures or menus.
    let interactive: Bool
    let onOpen: (DiagramTable) -> Void

    @State private var dragStart: CGPoint?

    static let space = "diagram"
    static let background = Color(nsColor: .underPageBackgroundColor)

    var body: some View {
        let size = model.canvasSize
        let highlighted = model.highlightedTables
        ZStack(alignment: .topLeading) {
            DiagramLines(model: model)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            ForEach(model.tables) { table in
                let frame = model.frame(of: table)
                box(for: table)
                    .frame(width: frame.width, height: frame.height)
                    .opacity(highlighted.isEmpty || highlighted.contains(table.id) ? 1 : 0.35)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder private func box(for table: DiagramTable) -> some View {
        let box = DiagramTableBox(
            table: table,
            columns: model.visibleColumns(of: table),
            foreignKeyColumns: model.foreignKeyColumns(of: table),
            isSelected: model.selectedTable == table.id
        )
        if interactive {
            box
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            let start = dragStart ?? model.frame(of: table).origin
                            dragStart = start
                            model.selectedTable = table.id
                            model.move(table.id, to: CGPoint(x: start.x + value.translation.width,
                                                             y: start.y + value.translation.height))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .onTapGesture(count: 2) { onOpen(table) }
                .onTapGesture { model.selectedTable = model.selectedTable == table.id ? nil : table.id }
                .contextMenu {
                    Button("Open Table") { onOpen(table) }
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(table.ref.name, forType: .string)
                    }
                }
                .help(summary(of: table))
        } else {
            box
        }
    }

    /// Tooltip: which tables this one references and is referenced by.
    private func summary(of table: DiagramTable) -> String {
        let names = Dictionary(model.tables.map { ($0.id, $0.ref.name) }, uniquingKeysWith: { first, _ in first })
        let references = model.relations.filter { $0.child == table.id }.compactMap { names[$0.parent] }
        let referencedBy = model.relations.filter { $0.parent == table.id }.compactMap { names[$0.child] }
        var lines = [table.ref.name]
        if !references.isEmpty { lines.append("References: " + Self.unique(references).joined(separator: ", ")) }
        if !referencedBy.isEmpty { lines.append("Referenced by: " + Self.unique(referencedBy).joined(separator: ", ")) }
        if references.isEmpty, referencedBy.isEmpty { lines.append("No relationships in this schema") }
        return lines.joined(separator: "\n")
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}

// MARK: - Table box

private struct DiagramTableBox: View {
    let table: DiagramTable
    let columns: [ColumnInfo]
    let foreignKeyColumns: Set<String>
    let isSelected: Bool

    private let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(table.ref.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: RelationshipDiagramModel.headerHeight,
                   maxHeight: RelationshipDiagramModel.headerHeight, alignment: .leading)
            .background(Color.accentColor.opacity(isSelected ? 0.25 : 0.12))
            Divider()
            if columns.isEmpty {
                Text("No key columns")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: RelationshipDiagramModel.rowHeight)
            }
            ForEach(columns) { column in
                row(column)
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                               lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Table \(table.ref.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func row(_ column: ColumnInfo) -> some View {
        HStack(spacing: 5) {
            Group {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                        .help("Primary key")
                } else if foreignKeyColumns.contains(column.name) {
                    Image(systemName: "link")
                        .foregroundStyle(.tint)
                        .help("Foreign key")
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 12)
            Text(column.name)
                .fontWeight(column.isPrimaryKey ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(column.dataType)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: RelationshipDiagramModel.rowHeight)
    }
}

// MARK: - Lines

/// One line per foreign key, from the referencing column's row to the referenced column's row.
private struct DiagramLines: View {
    let model: RelationshipDiagramModel

    var body: some View {
        let tables = Dictionary(model.tables.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = model.selectedTable
        Canvas { context, _ in
            for relation in model.relations {
                guard let child = tables[relation.child], let parent = tables[relation.parent] else { continue }
                let isHighlighted = selected != nil && (relation.child == selected || relation.parent == selected)
                let isDimmed = selected != nil && !isHighlighted
                let color: Color = isHighlighted ? .accentColor : .secondary
                let style = StrokeStyle(lineWidth: isHighlighted ? 2 : 1.2, lineCap: .round, lineJoin: .round)
                var layer = context
                layer.opacity = isDimmed ? 0.2 : 1
                let shape = Self.shape(for: relation, child: child, parent: parent, model: model)
                layer.stroke(shape.line, with: .color(color), style: style)
                if let circle = shape.circle {
                    // Filled, so the line doesn't show through it.
                    layer.fill(Path(ellipseIn: circle), with: .color(DiagramCanvas.background))
                    layer.stroke(Path(ellipseIn: circle), with: .color(color), style: style)
                }
            }
        }
    }

    /// Where a line leaves a box: a point on its left or right edge, and the outward direction (-1 or 1).
    private struct End {
        var point: CGPoint
        var direction: CGFloat
    }

    static let stub: CGFloat = 16

    /// The line with its end markers, and the circle marking an optional reference.
    static func shape(for relation: DiagramRelation, child: DiagramTable, parent: DiagramTable,
                      model: RelationshipDiagramModel) -> (line: Path, circle: CGRect?) {
        let childFrame = model.frame(of: child)
        let parentFrame = model.frame(of: parent)
        let childY = model.rowMidY(of: relation.columns.first, in: child, frame: childFrame)
        let parentY = model.rowMidY(of: relation.referencedColumns.first, in: parent, frame: parentFrame)

        let start: End
        let end: End
        if childFrame.minX > parentFrame.maxX + stub * 2 {
            start = End(point: CGPoint(x: childFrame.minX, y: childY), direction: -1)
            end = End(point: CGPoint(x: parentFrame.maxX, y: parentY), direction: 1)
        } else if childFrame.maxX + stub * 2 < parentFrame.minX {
            start = End(point: CGPoint(x: childFrame.maxX, y: childY), direction: 1)
            end = End(point: CGPoint(x: parentFrame.minX, y: parentY), direction: -1)
        } else {
            // Stacked or self-referencing: loop out to the right of both boxes.
            start = End(point: CGPoint(x: childFrame.maxX, y: childY), direction: 1)
            end = End(point: CGPoint(x: parentFrame.maxX, y: parentY), direction: 1)
        }

        var path = Path()
        let from = CGPoint(x: start.point.x + start.direction * stub, y: start.point.y)
        let to = CGPoint(x: end.point.x + end.direction * stub, y: end.point.y)
        let reach = max(40, abs(to.x - from.x) / 2, start.direction == end.direction ? abs(to.y - from.y) / 3 : 0)
        path.move(to: start.point)
        path.addLine(to: from)
        path.addCurve(to: to,
                      control1: CGPoint(x: from.x + start.direction * reach, y: from.y),
                      control2: CGPoint(x: to.x + end.direction * reach, y: to.y))
        path.addLine(to: end.point)

        // Referencing end: crow's foot (many), or a bar for a one-to-one key.
        if relation.isOneToOne {
            bar(at: start, distance: 8, in: &path)
        } else {
            let tip = CGPoint(x: start.point.x + start.direction * 12, y: start.point.y)
            for dy in [-6.0, 6.0] {
                path.move(to: tip)
                path.addLine(to: CGPoint(x: start.point.x, y: start.point.y + dy))
            }
        }
        // Referenced end: a bar (exactly one), and a circle further out when the reference is optional.
        bar(at: end, distance: 7, in: &path)
        guard relation.isOptional else {
            bar(at: end, distance: 11, in: &path)
            return (path, nil)
        }
        let center = CGPoint(x: end.point.x + end.direction * 14, y: end.point.y)
        return (path, CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
    }

    private static func bar(at end: End, distance: CGFloat, in path: inout Path) {
        let x = end.point.x + end.direction * distance
        path.move(to: CGPoint(x: x, y: end.point.y - 6))
        path.addLine(to: CGPoint(x: x, y: end.point.y + 6))
    }
}
