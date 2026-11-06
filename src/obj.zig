const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

pub const Mesh = struct {
    // vertices
    verts: []usize,
    // faces (triangles)
    tris: []f32,
};

pub fn parse(r: *Io.Reader, verts: []usize, tris: []f32) !Mesh {
    var it = mem.splitScalar(u8, r.buffered(), '\n');
    var i_tris: usize = 0;
    var i_verts: usize = 0;

    while (it.next()) |line| {
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
                var it2 = mem.tokenizeScalar(u8, line[1..], ' ');
                while (it2.next()) |digit| {
                    tris[i_tris] = try std.fmt.parseFloat(f32, digit);
                    i_tris += 1;
                }
            },

            'f' => {
                var it2 = mem.tokenizeScalar(u8, line[1..], ' ');
                outer: while (it2.next()) |idx| : (i_verts += 1) {
                    var it_vn = mem.tokenizeAny(u8, idx, "//");

                    // f v1//vn1 v2//vn2 v3//vn3 => vertex and normals but no texture
                    if (it_vn.peek() != null) {
                        verts[i_verts] =
                            try std.fmt.parseUnsigned(usize, it_vn.next().?, 10);
                        // todo: support normal
                        continue :outer;
                    }

                    var it_vtn = mem.tokenizeScalar(u8, idx, '/');

                    // f v1/vt1 v2/vt2 v3/vt3 => vertex and texture
                    // f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 =>
                    //     vertex, texture coords, normals
                    if (it_vtn.peek() != null) {
                        verts[i_verts] =
                            try std.fmt.parseUnsigned(usize, it_vtn.next().?, 10);
                        // todo: support normal and texture
                        continue :outer;
                    }

                    // f v1 v2 v3
                    verts[i_verts] = try std.fmt.parseUnsigned(usize, idx, 10);
                }
            },
            // g text => groups
            else => {},
        }
    }

    return .{ .tris = tris[0..i_tris], .verts = verts[0..i_verts] };
}

const expect = std.testing.expect;

test "parse" {
    const gpa = std.testing.allocator;
    const io = @constCast(&Io.Threaded.init(gpa, .{})).io();
    const file = try Io.Dir.cwd().openFile(io, "cube.obj", .{});

    var buf: [500]u8 = undefined;
    const read = try file.readPositionalAll(io, &buf, 0);
    const slice = buf[0..read];

    var r = Io.Reader.fixed(slice);
    var verts: [100]usize = undefined;
    var tris: [100]f32 = undefined;
    const res = try parse(&r, &verts, &tris);

    try expect(std.mem.eql(f32, res.tris, &[_]f32{
        1,  1,  1,
        -1, 1,  1,
        -1, -1, 1,
        1,  -1, 1,
        -1, 1,  -1,
        1,  1,  -1,
        1,  -1, -1,
        -1, -1, -1,
    }));
    try expect(std.mem.eql(usize, res.verts, &[_]usize{
        0, 1, 2,
        0, 2, 3,
        4, 5, 6,
        4, 6, 7,
        0, 3, 6,
        0, 6, 5,
        1, 4, 7,
        1, 7, 2,
        1, 0, 5,
        1, 5, 4,
        2, 7, 6,
        2, 6, 3,
    }));
}
