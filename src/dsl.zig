const std = @import("std");

/// Create a raw SQL fragment.
pub fn raw(comptime sql: []const u8, bindings: anytype) Raw(sql, @TypeOf(bindings)) {
    return .{ .bindings = bindings };
}

/// Create select query.
pub fn query(comptime T: type) Query(T, Raw(tableName(T), void), Where(void)) {
    return .{ .frm = undefined, .whr = undefined };
}

/// Create an insert query.
pub fn insert(comptime T: type) Insert(T, tableName(T), struct {}) {
    return undefined; // ZST
}

/// Create an update query.
pub fn update(comptime T: type) Update(T, tableName(T), Where(void), struct {}) {
    return undefined; // ZST
}

/// Create a delete query.
pub fn delete(comptime T: type) Delete(T, tableName(T), Where(void)) {
    return undefined; // ZST
}

fn tableName(comptime T: type) []const u8 {
    return comptime brk: {
        const s = @typeName(T);
        const i = std.mem.lastIndexOfScalar(u8, s, '.').?;
        break :brk s[i + 1 ..];
    };
}

fn fields(comptime T: type) []const u8 {
    return comptime brk: {
        var res: []const u8 = "";

        for (@typeInfo(T).Struct.fields) |f| {
            if (res.len > 0) res = res ++ ", ";
            res = res ++ f.name;
        }

        break :brk res;
    };
}

fn placeholders(comptime T: type) []const u8 {
    return comptime brk: {
        var res: []const u8 = "";

        for (@typeInfo(T).Struct.fields) |_| {
            if (res.len > 0) res = res ++ ", ";
            res = res ++ "?";
        }

        break :brk res;
    };
}

fn setters(comptime T: type) []const u8 {
    return comptime brk: {
        var res: []const u8 = "";

        for (@typeInfo(T).Struct.fields) |f| {
            if (res.len > 0) res = res ++ ", ";
            res = res ++ f.name ++ " = ?";
            break :brk res;
        }

        break :brk res;
    };
}

pub fn Raw(comptime raw_sql: []const u8, comptime T: type) type {
    return struct {
        bindings: T,

        pub inline fn sql(_: *const @This(), buf: *std.ArrayList(u8)) !void {
            try buf.appendSlice(raw_sql);
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            if (comptime T == void) return;

            inline for (@typeInfo(T).Struct.fields) |f| {
                try stmt.bind(counter.*, @field(self.bindings, f.name));
            }
        }
    };
}

pub fn Where(comptime Head: type) type {
    return struct {
        head: Head,

        pub fn andWhere(self: *const @This(), part: anytype) Cons(@TypeOf(part)) {
            return cons(self, " AND ", part);
        }

        pub fn orWhere(self: *const @This(), part: anytype) Cons(@TypeOf(part)) {
            return cons(self, " OR ", part);
        }

        pub fn sql(self: *const @This(), buf: *std.ArrayList(u8)) !void {
            if (comptime Head == void) return;

            try buf.appendSlice(" WHERE ");
            try sqlPart(self.head, buf);
        }

        fn sqlPart(part: anytype, buf: *std.ArrayList(u8)) !void {
            const T = @TypeOf(part);

            if (comptime @hasDecl(T, "sql")) {
                return part.sql(buf);
            }

            if (comptime @typeInfo(T) == .Struct and @typeInfo(T).Struct.fields.len == 3) {
                try sqlPart(part[0], buf);
                try buf.appendSlice(part[1]);
                try sqlPart(part[2], buf);
            } else {
                inline for (@typeInfo(T).Struct.fields) |f| {
                    try buf.appendSlice(comptime f.name ++ " = ?");
                }
            }
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            if (comptime Head == void) return;

            try bindPart(self.head, stmt, counter);
        }

        fn bindPart(part: anytype, stmt: anytype, counter: *usize) !void {
            const T = @TypeOf(part);

            if (comptime @hasDecl(T, "bind")) {
                return part.bind(stmt, counter);
            }

            if (comptime @typeInfo(T) == .Struct and @typeInfo(T).Struct.fields.len == 3) {
                try bindPart(part[0], stmt, counter);
                try bindPart(part[2], stmt, counter);
            } else {
                inline for (@typeInfo(T).Struct.fields) |f| {
                    try stmt.bind(counter.*, @field(part, f.name));
                    counter.* += 1;
                }
            }
        }

        pub fn Cons(comptime T: type) type {
            if (Head == void) return Where(T);

            return Where(struct { Head, []const u8, T });
        }

        fn cons(self: *const @This(), op: []const u8, part: anytype) Cons(@TypeOf(part)) {
            if (comptime Head == void) return .{ .head = part };

            return Cons(@TypeOf(part)){ .head = .{ self.head, op, part } };
        }
    };
}

pub fn Query(comptime T: type, comptime From: type, comptime W: type) type {
    return struct {
        pub const Row = T;

        frm: From,
        whr: W,
        ord: ?[]const u8 = null,

        pub fn from(self: *const @This(), frm: anytype) Query(T, @TypeOf(frm), W) {
            return .{ .frm = frm, .whr = self.whr };
        }

        pub fn where(self: *const @This(), criteria: anytype) Query(T, From, W.Cons(@TypeOf(criteria))) {
            return .{ .frm = self.frm, .whr = self.whr.andWhere(criteria) };
        }

        pub fn orWhere(self: *const @This(), criteria: anytype) Query(T, From, W.Cons(@TypeOf(criteria))) {
            return .{ .frm = self.frm, .whr = self.whr.orWhere(criteria) };
        }

        pub fn orderBy(self: *const @This(), col: std.meta.FieldEnum(T), ord: enum { asc, desc }) Query(T, From, W) {
            return self.orderByRaw(switch (col) {
                inline else => |c| switch (ord) {
                    inline else => |o| @tagName(c) ++ " " ++ @tagName(o),
                },
            });
        }

        pub fn orderByRaw(self: *const @This(), order_by: []const u8) Query(T, From, W) {
            return .{ .frm = self.frm, .whr = self.whr, .ord = order_by };
        }

        pub fn sql(self: *const @This(), buf: *std.ArrayList(u8)) !void {
            try buf.appendSlice(comptime "SELECT " ++ fields(T) ++ " FROM ");
            try self.frm.sql(buf);
            try self.whr.sql(buf);

            if (self.ord) |ord| {
                try buf.appendSlice(" ORDER BY ");
                try buf.appendSlice(ord);
            }
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            try self.frm.bind(stmt, counter);
            try self.whr.bind(stmt, counter);
        }
    };
}

pub fn Insert(comptime T: type, comptime into: []const u8, comptime V: type) type {
    return struct {
        pub const Row = T;

        data: V,

        pub fn values(_: *const @This(), data: anytype) Insert(T, into, @TypeOf(data)) {
            // TODO: comptime checkFields(Payload(T), @TypeOf(data))
            return .{ .data = data };
        }

        pub fn sql(_: *const @This(), buf: *std.ArrayList(u8)) !void {
            try buf.appendSlice(comptime "INSERT INTO " ++ into ++ "(" ++ fields(V) ++ ") VALUES (" ++ placeholders(V) ++ ")");
        }

        pub fn build(self: *const @This(), builder: anytype) !void {
            try builder.push(self.data);
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            inline for (@typeInfo(V).Struct.fields) |f| {
                try stmt.bind(counter.*, @field(self.data, f.name));
                counter.* += 1;
            }
        }
    };
}

pub fn Update(comptime T: type, comptime tbl: []const u8, comptime W: type, comptime V: type) type {
    return struct {
        pub const Row = T;

        whr: W,
        data: V,

        pub fn table(self: *const @This(), table_name: []const u8) Update(T, table_name, W) {
            return .{ .whr = self.whr };
        }

        pub fn where(self: *const @This(), criteria: anytype) Update(T, tbl, W.Cons(@TypeOf(criteria)), V) {
            return .{ .whr = self.whr.andWhere(criteria), .data = self.data };
        }

        pub fn orWhere(self: *const @This(), criteria: anytype) Update(T, tbl, W.Cons(@TypeOf(criteria)), V) {
            return .{ .whr = self.whr.orWhere(criteria), .data = self.data };
        }

        pub fn set(self: *const @This(), data: anytype) Update(T, tbl, W, @TypeOf(data)) {
            return .{ .whr = self.whr, .data = data };
        }

        pub fn sql(self: *const @This(), buf: *std.ArrayList(u8)) !void {
            try buf.appendSlice(comptime "UPDATE " ++ tbl ++ " SET " ++ setters(V));
            try self.whr.sql(buf);
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            inline for (@typeInfo(V).Struct.fields) |f| {
                try stmt.bind(counter.*, @field(self.data, f.name));
                counter.* += 1;
            }

            try self.whr.bind(stmt, counter);
        }
    };
}

pub fn Delete(comptime T: type, comptime tbl: []const u8, comptime W: type) type {
    return struct {
        pub const Row = T;

        whr: W,

        pub fn from(self: *const @This(), table_name: []const u8) Delete(T, table_name, W) {
            return .{ .whr = self.whr };
        }

        pub fn where(self: *const @This(), criteria: anytype) Delete(T, tbl, W.Cons(@TypeOf(criteria))) {
            return .{ .whr = self.whr.andWhere(criteria) };
        }

        pub fn orWhere(self: *const @This(), criteria: anytype) Delete(T, tbl, W.Cons(@TypeOf(criteria))) {
            return .{ .whr = self.whr.orWhere(criteria) };
        }

        pub fn sql(self: *const @This(), buf: *std.ArrayList(u8)) !void {
            try buf.appendSlice(comptime "DELETE FROM " ++ tbl);
            try self.whr.sql(buf);
        }

        pub fn bind(self: *const @This(), stmt: anytype, counter: *usize) !void {
            try self.whr.bind(stmt, counter);
        }
    };
}

fn expectSql(q: anytype, sql: []const u8) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try q.sql(&buf);
    try std.testing.expectEqualStrings(sql, buf.items);
}

const Person = struct {
    id: u32,
    name: []const u8,
    age: u8,
};

test "where" {
    const where: Where(void) = undefined;
    const name = raw("name = ?", .{"Alice"});
    const age = raw("age = ?", .{20});

    try expectSql(where, "");

    try expectSql(where.andWhere(name), " WHERE name = ?");
    try expectSql(where.andWhere(name).andWhere(age), " WHERE name = ? AND age = ?");

    try expectSql(where.orWhere(name), " WHERE name = ?");
    try expectSql(where.orWhere(name).orWhere(age), " WHERE name = ? OR age = ?");
}

test "query" {
    try expectSql(query(Person), "SELECT id, name, age FROM Person");

    try expectSql(
        query(Person).where(.{ .name = "Alice" }),
        "SELECT id, name, age FROM Person WHERE name = ?",
    );

    try expectSql(
        query(Person).where(.{ .name = "Alice" }).orWhere(.{ .age = 20 }),
        "SELECT id, name, age FROM Person WHERE name = ? OR age = ?",
    );

    try expectSql(
        query(Person).orderBy(.name, .asc),
        "SELECT id, name, age FROM Person ORDER BY name asc",
    );
}

test "insert" {
    try expectSql(insert(Person), "INSERT INTO Person() VALUES ()");

    try expectSql(
        insert(Person).values(.{ .name = "Alice", .age = 20 }),
        "INSERT INTO Person(name, age) VALUES (?, ?)",
    );
}

test "update" {
    try expectSql(update(Person).set(.{ .name = "Alice" }), "UPDATE Person SET name = ?");

    try expectSql(
        update(Person).set(.{ .name = "Alice" }).where(.{ .age = 20 }),
        "UPDATE Person SET name = ? WHERE age = ?",
    );

    try expectSql(
        update(Person).set(.{ .name = "Alice" }).where(.{ .age = 20 }).orWhere(.{ .name = "Bob" }),
        "UPDATE Person SET name = ? WHERE age = ? OR name = ?",
    );
}

test "delete" {
    try expectSql(delete(Person), "DELETE FROM Person");

    try expectSql(
        delete(Person).where(.{ .age = 20 }),
        "DELETE FROM Person WHERE age = ?",
    );

    try expectSql(
        delete(Person).where(.{ .age = 20 }).orWhere(.{ .name = "Bob" }),
        "DELETE FROM Person WHERE age = ? OR name = ?",
    );
}