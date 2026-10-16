import CoreGraphics
import Foundation
import Testing
@testable import Dbee

@MainActor
@Suite("RelationshipDiagram")
struct RelationshipDiagramTests {
    // MARK: Layout

    private static func node(_ id: String, height: CGFloat = 100) -> DiagramLayout.Node {
        DiagramLayout.Node(id: id, size: CGSize(width: 200, height: height))
    }

    private static func frames(_ nodes: [DiagramLayout.Node], _ positions: [String: CGPoint]) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGRect(origin: positions[$0.id] ?? .zero, size: $0.size)) })
    }

    @Test func referencedTablesSitLeftOfReferencingTables() {
        let nodes = ["orders", "users", "items", "products"].map { Self.node($0) }
        let edges = [
            DiagramLayout.Edge(from: "orders", to: "users"),
            DiagramLayout.Edge(from: "items", to: "orders"),
            DiagramLayout.Edge(from: "items", to: "products"),
        ]
        let frames = Self.frames(nodes, DiagramLayout.positions(nodes: nodes, edges: edges))
        #expect(frames["users"]!.maxX < frames["orders"]!.minX)
        #expect(frames["orders"]!.maxX < frames["items"]!.minX)
        // Referenced only by items, so it moves up next to it instead of staying in the first layer.
        #expect(frames["products"]!.maxX < frames["items"]!.minX)
        #expect(frames["products"]!.minX > frames["users"]!.maxX)
    }

    @Test func noTablesOverlapAndAllAreInsideTheMargin() {
        var nodes: [DiagramLayout.Node] = []
        var edges: [DiagramLayout.Edge] = []
        // A hub referenced by many tables (so its layer wraps), a cycle, a self reference and loose tables.
        nodes.append(Self.node("hub"))
        for i in 0..<30 {
            nodes.append(Self.node("t\(i)", height: CGFloat(60 + (i % 5) * 40)))
            edges.append(DiagramLayout.Edge(from: "t\(i)", to: "hub"))
        }
        nodes += ["a", "b", "c", "self"].map { Self.node($0) }
        edges += [
            DiagramLayout.Edge(from: "a", to: "b"),
            DiagramLayout.Edge(from: "b", to: "c"),
            DiagramLayout.Edge(from: "c", to: "a"),
            DiagramLayout.Edge(from: "self", to: "self"),
            DiagramLayout.Edge(from: "a", to: "missing"),
        ]
        for i in 0..<12 { nodes.append(Self.node("loose\(i)", height: 80)) }

        let positions = DiagramLayout.positions(nodes: nodes, edges: edges)
        #expect(positions.count == nodes.count)
        let frames = Array(Self.frames(nodes, positions).values)
        for frame in frames {
            #expect(frame.minX >= DiagramLayout.margin && frame.minY >= DiagramLayout.margin)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
        // The hub's 30 referencing tables wrap into several columns rather than one tower.
        let referencingColumns = Set((0..<30).map { positions["t\($0)"]!.x })
        #expect(referencingColumns.count > 1)
    }

    @Test func emptyDiagramHasNoPositions() {
        #expect(DiagramLayout.positions(nodes: [], edges: []).isEmpty)
    }

    // MARK: Relations

    private static func column(_ name: String, pk: Bool = false, nullable: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, dataType: "integer", isNullable: nullable, defaultValue: nil, isPrimaryKey: pk, comment: nil)
    }

    private static func key(_ name: String, _ columns: [String], to table: TableRef, _ referenced: [String]) -> ForeignKeyInfo {
        ForeignKeyInfo(name: name, columns: columns, referencedTable: table, referencedColumns: referenced,
                       onUpdate: nil, onDelete: nil)
    }

    @Test func relationsResolveTablesAndCardinality() {
        let users = DiagramTable(ref: TableRef(schema: nil, name: "users"), columns: [Self.column("id", pk: true)], foreignKeys: [])
        let profiles = DiagramTable(
            ref: TableRef(schema: nil, name: "profiles"),
            columns: [Self.column("user_id", pk: true)],
            foreignKeys: [Self.key("profiles_user", ["user_id"], to: TableRef(schema: nil, name: "users"), ["id"])]
        )
        let posts = DiagramTable(
            ref: TableRef(schema: nil, name: "posts"),
            columns: [Self.column("id", pk: true), Self.column("author", nullable: true), Self.column("org")],
            foreignKeys: [
                // SQLite keeps the name as written in REFERENCES.
                Self.key("posts_author", ["author"], to: TableRef(schema: nil, name: "Users"), ["id"]),
                Self.key("posts_org", ["org"], to: TableRef(schema: "elsewhere", name: "orgs"), ["id"]),
            ]
        )
        let (relations, external) = RelationshipDiagramModel.relations(of: [users, profiles, posts])
        #expect(external == 1)
        #expect(relations.count == 2)

        let profile = try! #require(relations.first { $0.name == "profiles_user" })
        #expect(profile.child == profiles.id && profile.parent == users.id)
        #expect(profile.isOneToOne && !profile.isOptional)

        let author = try! #require(relations.first { $0.name == "posts_author" })
        #expect(author.parent == users.id)
        #expect(!author.isOneToOne && author.isOptional)
    }

    // MARK: Loading

    @Test func sqliteDiagramReadsTablesAndSkipsViews() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbee-diagram-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let driver = try SQLiteDriver.open(path: path, create: true)
        for sql in [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
            "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users (id), body TEXT)",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, text TEXT)",
            "CREATE VIEW recent AS SELECT * FROM posts",
        ] {
            _ = try await driver.execute(sql, maxRows: 0)
        }
        let schema = try #require(try await driver.listSchemas().first)
        let tables = try await driver.diagramTables(in: schema)
        await driver.close()

        #expect(tables.map(\.ref.name).sorted() == ["notes", "posts", "users"])
        let posts = try #require(tables.first { $0.ref.name == "posts" })
        #expect(posts.foreignKeys.map(\.referencedTable.name) == ["users"])

        let session = DatabaseSession()
        let model = RelationshipDiagramModel(session: session, schema: schema.name)
        model.apply(tables)
        #expect(model.relations.count == 1)
        #expect(model.positions.count == 3)
        #expect(model.visibleColumns(of: posts).map(\.name) == ["id", "user_id", "body"])

        model.keysOnly = true
        #expect(model.visibleColumns(of: posts).map(\.name) == ["id", "user_id"])
        let notes = try #require(model.tables.first { $0.ref.name == "notes" })
        #expect(model.visibleColumns(of: notes).map(\.name) == ["id"])

        // A refresh with the same tables keeps the user's arrangement.
        model.move(posts.id, to: CGPoint(x: 900, y: 700))
        model.apply(tables)
        #expect(model.positions[posts.id] == CGPoint(x: 900, y: 700))
    }
}
