const Vec3 = @Vector(3, f32);
const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

pub const Mesh = struct {
    // vertices
    mesh: []Vec3,
    // faces (triangles)
    tris: []usize,
};

pub fn open(name: []const u8, arena: *std.heap.ArenaAllocator, io: Io) !Mesh {
    const gpa = arena.allocator();
    const file = try Io.Dir.cwd().openFile(io, name, .{});

    var buf = try gpa.alloc(u8, try file.length(io));
    const read = try file.readPositionalAll(io, buf, 0);
    const filebuf = buf[0..read];

    const verts: []usize = try gpa.alloc(usize, buf.len);
    const tris: []Vec3 = try gpa.alloc(Vec3, buf.len);

    return try parse(filebuf, verts, tris);
}

var tmp: [8]usize = undefined;

fn parse(buf: []const u8, verts: []usize, tris: []Vec3) !Mesh {
    var it_lines = mem.splitScalar(u8, buf, '\n');
    var i_tris: usize = 0;
    var i_verts: usize = 0;

    while (it_lines.next()) |line| {
        if (line.len < 1) continue;
        switch (line[0]) {
            'v' => {
                switch (line[1]) {
                    // vt => texture coordinates (s or uv) with 2 floats
                    't' => {
                        continue;
                    },
                    // vn => normal with 3 floats
                    'n' => {
                        continue;
                    },
                    ' ' => {},
                    else => continue,
                }
                var it = mem.tokenizeScalar(u8, line[2..], ' ');
                tris[i_tris][0] = try std.fmt.parseFloat(f32, it.next().?);
                tris[i_tris][1] = try std.fmt.parseFloat(f32, it.next().?);
                tris[i_tris][2] = try std.fmt.parseFloat(f32, it.next().?);
                i_tris += 1;
            },

            'f' => {
                var it = mem.tokenizeScalar(u8, line[2..], ' ');

                var i: usize = 0;
                outer: while (it.next()) |idx| : (i += 1) {
                    var it_vn = mem.tokenizeAny(u8, idx, "//");

                    // f v1//vn1 v2//vn2 v3//vn3 => vertex and normals but no texture
                    if (it_vn.peek() != null) {
                        tmp[i] = try std.fmt.parseUnsigned(usize, it_vn.next().?, 10);
                        // todo: support normal
                        continue :outer;
                    }

                    var it_vtn = mem.tokenizeScalar(u8, idx, '/');

                    // f v1/vt1 v2/vt2 v3/vt3 => vertex and texture
                    // f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 =>
                    //     vertex, texture coords, normals
                    if (it_vtn.peek() != null) {
                        tmp[i] =
                            try std.fmt.parseUnsigned(usize, it_vtn.next().?, 10);
                        // todo: support normal and texture
                        continue :outer;
                    }

                    // f v1 v2 v3
                    tmp[i] = try std.fmt.parseUnsigned(usize, idx, 10);
                }

                // break down quads (or more) into triangles
                var k: usize = 1;
                while (k + 1 < i) : (k += 1) {
                    verts[i_verts + 0] = tmp[0];
                    verts[i_verts + 1] = tmp[k];
                    verts[i_verts + 2] = tmp[k + 1];
                    i_verts += 3;
                }
            },
            // g text => groups
            else => {},
        }
    }

    return .{ .mesh = tris[0..i_tris], .tris = verts[0..i_verts] };
}

const expect = std.testing.expect;

test "parse" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = @constCast(&Io.Threaded.init(std.testing.allocator, .{})).io();
    const file = try Io.Dir.cwd().openFile(io, "cube.obj", .{});

    var buf: [10 * 20]u8 = undefined;
    const read = try file.readPositionalAll(io, &buf, 0);
    const slice = buf[0..read];

    var tris: [8 * 3]Vec3 = undefined;
    var verts: [12 * 3]usize = undefined;
    const res = try parse(slice, &verts, &tris);

    const expected = [_]Vec3{
        // zig fmt: off
        .{  1,  1,  1 },
        .{ -1,  1,  1 },
        .{ -1, -1,  1 },
        .{  1, -1,  1 },
        .{ -1,  1, -1 },
        .{  1,  1, -1 },
        .{  1, -1, -1 },
        .{ -1, -1, -1 },
        // zig fmt: on
    };

    for (res.mesh, expected) |v, e| {
        try expect(v[0] == e[0]);
        try expect(v[1] == e[1]);
        try expect(v[2] == e[2]);
    }

    // obj files are 1 index based
    try expect(std.mem.eql(usize, res.tris, &[_]usize{
        1, 2, 3,
        1, 3, 4,
        5, 6, 7,
        5, 7, 8,
        1, 4, 7,
        1, 7, 6,
        2, 5, 8,
        2, 8, 3,
        2, 1, 6,
        2, 6, 5,
        3, 8, 7, // i 33 + 3 = 36
        3, 7, 4, // i 36
    }));
}
