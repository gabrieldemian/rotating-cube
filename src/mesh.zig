pub const Vec3 = @Vector(3, f32);
pub const Vec2 = @Vector(2, f32);
const std = @import("std");
const zigimg = @import("zigimg");
const colors = @import("colors.zig");
const utils = @import("utils.zig");
const term = @import("term.zig");
const root = @import("root");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const MeshKind = enum(u8) { texture, no_texture };

var mesh_textures: [255]MeshTexture = undefined;
var textures_len: u8 = 0; // non inclusive

pub const Mesh = struct {
    kind: MeshKind,
    /// index into specializations of `Mesh`.
    extra_index: u8,
    /// vertices
    mesh: []Vec3,
    /// faces. indexes `mesh`.
    faces: []usize,

    pub fn open(
        name: []const u8,
        arena: *std.heap.ArenaAllocator,
        io: Io,
    ) !Mesh {
        const gpa = arena.allocator();
        const file = try Io.Dir.cwd().openFile(io, name, .{});

        var buf = try gpa.alloc(u8, try file.length(io));
        const read = try file.readPositionalAll(io, buf, 0);
        const filebuf = buf[0..read];

        const verts: []usize = try gpa.alloc(usize, buf.len);
        const tris: []Vec3 = try gpa.alloc(Vec3, buf.len);

        return try parse_no_texture(filebuf, verts, tris);
    }

    pub fn rasterize(
        self: Mesh,
        v0: Vec3,
        v1: Vec3,
        v2: Vec3,
        w0: f32,
        w1: f32,
        w2: f32,
        start_face_i: usize,
        buf: []u8,
        light: Vec3,
    ) void {
        const c0 = utils.project(t0, term.aspect);
        const c1 = utils.project(t1, term.aspect);
        const c2 = utils.project(t2, term.aspect);
        const ndcs = utils.clip(c0, c1, c2);

        switch (self.kind) {
            .no_texture => Mesh.rasterize_notexture(v0, v1, v2, buf, light),
            .texture => mesh_textures[self.extra_index].rasterize(
                v0,
                v1,
                v2,
                w0,
                w1,
                w2,
                start_face_i,
                buf,
                light,
            ),
        }
    }

    fn rasterize_notexture(v0: Vec3, v1: Vec3, v2: Vec3, buf: []u8, light: Vec3) void {
        const x_min: i32 = @floor(@min(v0[0], v1[0], v2[0]));
        const x_max: i32 = @ceil(@max(v0[0], v1[0], v2[0]));
        const y_min: i32 = @floor(@min(v0[1], v1[1], v2[1]));
        const y_max: i32 = @ceil(@max(v0[1], v1[1], v2[1]));

        var topleft = Vec3{ @floatFromInt(x_min), @floatFromInt(y_min), 0 };
        topleft += @splat(0.5);

        const bias: Vec3 = .{
            if (root.is_top_left(v1, v2)) 0 else -0.0000001,
            if (root.is_top_left(v2, v0)) 0 else -0.0000001,
            if (root.is_top_left(v0, v1)) 0 else -0.0000001,
        };

        const inv_area = 1.0 / utils.edge_cross(v0, v1, v2);
        var wleft = (Vec3{
            utils.edge_cross(v1, v2, topleft),
            utils.edge_cross(v2, v0, topleft),
            utils.edge_cross(v0, v1, topleft),
        } + bias); // divide by area for true bary and remove inv_area

        const dw_dx = Vec3{ v1[1] - v2[1], v2[1] - v0[1], v0[1] - v1[1] };
        const dw_dy = Vec3{ v2[0] - v1[0], v0[0] - v2[0], v1[0] - v0[0] };

        const dz_dx = (dw_dx[0] * v0[2] + dw_dx[1] * v1[2] + dw_dx[2] * v2[2]) * inv_area;
        const dz_dy = (dw_dy[0] * v0[2] + dw_dy[1] * v1[2] + dw_dy[2] * v2[2]) * inv_area;

        var z_left = (wleft[0] * v0[2] + wleft[1] * v1[2] + wleft[2] * v2[2]) * inv_area;
        var y = y_min;

        while (y < y_max) : (y += 1) {
            const row_start = @as(usize, @intCast(term.half_rows - 1 - y)) * term.cols;
            var x = x_min;
            var w = wleft;
            var z = z_left;

            while (x < x_max) : (x += 1) {
                if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                    const col: usize = @intCast(term.half_cols + x);
                    if (z < root.zbuf_raw[row_start + col]) {
                        root.zbuf_raw[row_start + col] = z;
                        term.put_cell_bg(buf, row_start + col, @round(colors.GREY * light));
                    }
                }
                w += dw_dx;
                z += dz_dx;
            }
            wleft += dw_dy;
            z_left += dz_dy;
        }
    }
};

pub const MeshTexture = struct {
    /// texture in UV coordinates
    uv: []Vec2,

    /// textures of each face. indexes `uv`.
    face_uvs: []usize,

    img: zigimg.Image,

    pub fn open(
        name: []const u8,
        texture: []const u8,
        arena: *std.heap.ArenaAllocator,
        io: Io,
    ) !Mesh {
        const gpa = arena.allocator();
        const file = try Io.Dir.cwd().openFile(io, name, .{});

        var buf = try gpa.alloc(u8, try file.length(io));
        const read = try file.readPositionalAll(io, buf, 0);
        const filebuf = buf[0..read];

        const verts: []usize = try gpa.alloc(usize, buf.len);
        const tris: []Vec3 = try gpa.alloc(Vec3, buf.len);
        const uv: []Vec2 = try gpa.alloc(Vec2, buf.len);
        const mesh_texts: []usize = try gpa.alloc(usize, buf.len);

        return try parse_with_texture(
            texture,
            filebuf,
            verts,
            tris,
            uv,
            mesh_texts,
            arena,
            io,
        );
    }

    pub fn rasterize(
        self: MeshTexture,
        v0: Vec3,
        v1: Vec3,
        v2: Vec3,
        w0: f32,
        w1: f32,
        w2: f32,
        start_face_i: usize,
        buf: []u8,
        light: Vec3,
    ) void {
        const x_min: i32 = @floor(@min(v0[0], v1[0], v2[0]));
        const x_max: i32 = @ceil(@max(v0[0], v1[0], v2[0]));
        const y_min: i32 = @floor(@min(v0[1], v1[1], v2[1]));
        const y_max: i32 = @ceil(@max(v0[1], v1[1], v2[1]));

        const uv0 = self.uv[self.face_uvs[start_face_i + 0]];
        const uv1 = self.uv[self.face_uvs[start_face_i + 1]];
        const uv2 = self.uv[self.face_uvs[start_face_i + 2]];

        var topleft = Vec3{ @floatFromInt(x_min), @floatFromInt(y_min), 0 };
        topleft += @splat(0.5);

        const bias: Vec3 = .{
            if (root.is_top_left(v1, v2)) 0 else -0.0000001,
            if (root.is_top_left(v2, v0)) 0 else -0.0000001,
            if (root.is_top_left(v0, v1)) 0 else -0.0000001,
        };

        const inv_area = 1.0 / utils.edge_cross(v0, v1, v2);
        var wleft = (Vec3{
            utils.edge_cross(v1, v2, topleft),
            utils.edge_cross(v2, v0, topleft),
            utils.edge_cross(v0, v1, topleft),
        } + bias); // divide by area for true bary and remove inv_area

        const dw_dx = Vec3{ v1[1] - v2[1], v2[1] - v0[1], v0[1] - v1[1] };
        const dw_dy = Vec3{ v2[0] - v1[0], v0[0] - v2[0], v1[0] - v0[0] };

        const dz_dx = (dw_dx[0] * v0[2] + dw_dx[1] * v1[2] + dw_dx[2] * v2[2]) * inv_area;
        const dz_dy = (dw_dy[0] * v0[2] + dw_dy[1] * v1[2] + dw_dy[2] * v2[2]) * inv_area;

        var z_left = (wleft[0] * v0[2] + wleft[1] * v1[2] + wleft[2] * v2[2]) * inv_area;
        var y = y_min;

        const iw0 = 1.0 / w0;
        const iw1 = 1.0 / w1;
        const iw2 = 1.0 / w2;

        const uow0 = uv0[0] * iw0;
        const uow1 = uv1[0] * iw1;
        const uow2 = uv2[0] * iw2;
        const vow0 = uv0[1] * iw0;
        const vow1 = uv1[1] * iw1;
        const vow2 = uv2[1] * iw2;

        const diw_dx = (dw_dx[0] * iw0 + dw_dx[1] * iw1 + dw_dx[2] * iw2) * inv_area;
        const duow_dx = (dw_dx[0] * uow0 + dw_dx[1] * uow1 + dw_dx[2] * uow2) * inv_area;
        const dvow_dx = (dw_dx[0] * vow0 + dw_dx[1] * vow1 + dw_dx[2] * vow2) * inv_area;
        const diw_dy = (dw_dy[0] * iw0 + dw_dy[1] * iw1 + dw_dy[2] * iw2) * inv_area;
        const duow_dy = (dw_dy[0] * uow0 + dw_dy[1] * uow1 + dw_dy[2] * uow2) * inv_area;
        const dvow_dy = (dw_dy[0] * vow0 + dw_dy[1] * vow1 + dw_dy[2] * vow2) * inv_area;

        var iw_left = (wleft[0] * iw0 + wleft[1] * iw1 + wleft[2] * iw2) * inv_area;
        var uow_left = (wleft[0] * uow0 + wleft[1] * uow1 + wleft[2] * uow2) * inv_area;
        var vow_left = (wleft[0] * vow0 + wleft[1] * vow1 + wleft[2] * vow2) * inv_area;

        while (y < y_max) : (y += 1) {
            const row_start = @as(usize, @intCast(term.half_rows - 1 - y)) * term.cols;
            var x = x_min;
            var w = wleft;
            var z = z_left;
            var iw = iw_left;
            var uow = uow_left;
            var vow = vow_left;

            while (x < x_max) : (x += 1) {
                if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                    const col: usize = @intCast(term.half_cols + x);
                    if (z < root.zbuf_raw[row_start + col]) {
                        root.zbuf_raw[row_start + col] = z;
                        const u = uow / iw;
                        const v = vow / iw;
                        const pixel = sample(u, v, self.img);
                        const color = @round(Vec3{
                            pixel.r * 255,
                            pixel.g * 255,
                            pixel.b * 255,
                        } * light);
                        term.put_cell_bg(buf, row_start + col, color);
                    }
                }
                w += dw_dx;
                z += dz_dx;
                iw += diw_dx;
                uow += duow_dx;
                vow += dvow_dx;
            }
            wleft += dw_dy;
            z_left += dz_dy;
            iw_left += diw_dy;
            uow_left += duow_dy;
            vow_left += dvow_dy;
        }
    }
};

fn open_texture(
    name: []const u8,
    arena: *std.heap.ArenaAllocator,
    io: Io,
) !zigimg.Image {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(arena.allocator(), io, name, &read_buffer);
    try image.convert(arena.allocator(), .float32);
    return image;
}

var tmp: [8]usize = undefined;
var tmp_texts: [8]usize = undefined;

fn parse_no_texture(buf: []const u8, faces: []usize, vertices: []Vec3) !Mesh {
    var it_lines = mem.splitScalar(u8, buf, '\n');
    var i_vert: usize = 0;
    var i_face: usize = 0;

    while (it_lines.next()) |line| {
        if (line.len < 1) continue;
        switch (line[0]) {
            'v' => {
                switch (line[1]) {
                    't' => continue,
                    'n' => continue,
                    ' ' => {},
                    else => continue,
                }
                var it = mem.tokenizeScalar(u8, line[2..], ' ');
                vertices[i_vert][0] = try std.fmt.parseFloat(f32, it.next().?);
                vertices[i_vert][1] = try std.fmt.parseFloat(f32, it.next().?);
                vertices[i_vert][2] = try std.fmt.parseFloat(f32, it.next().?);
                i_vert += 1;
            },

            'f' => {
                var it = mem.tokenizeScalar(u8, line[2..], ' ');
                var i: usize = 0;

                // iterate over spaces [1/1,2/3,3/4]
                outer: while (it.next()) |idx| : (i += 1) {
                    var it_vn = mem.tokenizeSequence(u8, idx, "//");
                    _ = it_vn.next().?;

                    // f v1//vn1 v2//vn2 v3//vn3 => vertex and normals but no texture
                    if (it_vn.next()) |pair| {
                        tmp[i] = try std.fmt.parseUnsigned(usize, pair, 10);
                        tmp_texts[i] = 1;
                        continue :outer;
                    }

                    var it_vtn = mem.tokenizeScalar(u8, idx, '/');

                    // f v1/vt1 v2/vt2 v3/vt3 => vertex and texture
                    // f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 => ... and normals
                    if (it_vtn.next()) |vistring| {
                        const vi = try std.fmt.parseUnsigned(usize, vistring, 10);
                        tmp[i] = vi;
                        if (it_vtn.next()) |text_line| {
                            tmp_texts[i] = try std.fmt.parseUnsigned(usize, text_line, 10);
                        }
                        continue :outer;
                    }

                    // f v1 v2 v3
                    tmp[i] = try std.fmt.parseUnsigned(usize, idx, 10);
                    tmp_texts[i] = 1;
                }

                // break down quads (or more) into triangles
                var k: usize = 1;
                while (k + 1 < i) : (k += 1) {
                    // obj files are 1 index based, i disrespect this
                    faces[i_face + 0] = tmp[0] - 1;
                    faces[i_face + 1] = tmp[k] - 1;
                    faces[i_face + 2] = tmp[k + 1] - 1;
                    i_face += 3;
                }
            },
            // g text => groups
            else => {},
        }
    }

    return .{
        .mesh = vertices[0..i_vert],
        .faces = faces[0..i_face],
        .extra_index = 0,
        .kind = .no_texture,
    };
}

fn parse_with_texture(
    texture_name: []const u8,
    buf: []const u8,
    faces: []usize,
    vertices: []Vec3,
    uv: []Vec2,
    face_uv: []usize,
    arena: *std.heap.ArenaAllocator,
    io: Io,
) !Mesh {
    var it_lines = mem.splitScalar(u8, buf, '\n');
    var i_vert: usize = 0;
    var i_face: usize = 0;
    var i_uv: usize = 0;

    while (it_lines.next()) |line| {
        if (line.len < 1) continue;
        switch (line[0]) {
            'v' => {
                switch (line[1]) {
                    // vt 0.169766 0.016610 (uv coords)
                    't' => {
                        var it = mem.tokenizeScalar(u8, line[2..], ' ');
                        uv[i_uv][0] = try std.fmt.parseFloat(f32, it.next().?);
                        uv[i_uv][1] = try std.fmt.parseFloat(f32, it.next().?);
                        i_uv += 1;
                        continue;
                    },
                    // vn => normal with 3 floats
                    'n' => continue,
                    ' ' => {},
                    else => continue,
                }
                var it = mem.tokenizeScalar(u8, line[2..], ' ');
                vertices[i_vert][0] = try std.fmt.parseFloat(f32, it.next().?);
                vertices[i_vert][1] = try std.fmt.parseFloat(f32, it.next().?);
                vertices[i_vert][2] = try std.fmt.parseFloat(f32, it.next().?);
                i_vert += 1;
            },

            'f' => {
                var it = mem.tokenizeScalar(u8, line[2..], ' ');
                var i: usize = 0;

                // iterate over spaces [1/1,2/3,3/4]
                outer: while (it.next()) |idx| : (i += 1) {
                    var it_vn = mem.tokenizeSequence(u8, idx, "//");
                    _ = it_vn.next().?;

                    // f v1//vn1 v2//vn2 v3//vn3 => vertex and normals but no texture
                    if (it_vn.next()) |pair| {
                        tmp[i] = try std.fmt.parseUnsigned(usize, pair, 10);
                        tmp_texts[i] = 1;
                        continue :outer;
                    }

                    var it_vtn = mem.tokenizeScalar(u8, idx, '/');

                    // f v1/vt1 v2/vt2 v3/vt3 => vertex and texture
                    // f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 =>
                    //     vertex, texture coords, normals
                    if (it_vtn.next()) |vistring| {
                        const vi = try std.fmt.parseUnsigned(usize, vistring, 10);
                        tmp[i] = vi;
                        if (it_vtn.next()) |text_line| {
                            tmp_texts[i] = try std.fmt.parseUnsigned(usize, text_line, 10);
                        }
                        continue :outer;
                    }

                    // f v1 v2 v3
                    tmp[i] = try std.fmt.parseUnsigned(usize, idx, 10);
                    tmp_texts[i] = 1;
                }

                // break down quads (or more) into triangles
                var k: usize = 1;
                while (k + 1 < i) : (k += 1) {
                    // obj files are 1 index based, i disrespect this
                    faces[i_face + 0] = tmp[0] - 1;
                    faces[i_face + 1] = tmp[k] - 1;
                    faces[i_face + 2] = tmp[k + 1] - 1;
                    face_uv[i_face + 0] = tmp_texts[0] - 1;
                    face_uv[i_face + 1] = tmp_texts[k] - 1;
                    face_uv[i_face + 2] = tmp_texts[k + 1] - 1;
                    i_face += 3;
                }
            },
            // g text => groups
            else => {},
        }
    }

    mesh_textures[textures_len] = .{
        .face_uvs = face_uv[0..i_face],
        .uv = uv[0..i_uv],
        .img = try open_texture(texture_name, arena, io),
    };

    defer textures_len += 1;

    return .{
        .kind = .texture,
        .extra_index = textures_len,
        .mesh = vertices[0..i_vert],
        .faces = faces[0..i_face],
    };
}

fn sample(u: f32, v: f32, img: zigimg.Image) zigimg.color.Colorf32 {
    const uw = u - @floor(u);
    const vw = v - @floor(v);
    const wf: f32 = @floatFromInt(img.width);
    const hf: f32 = @floatFromInt(img.height);
    const tx: usize = @min(@as(usize, @trunc(uw * wf)), img.width - 1);
    const row: usize = @min(@as(usize, @trunc(vw * hf)), img.height - 1);
    const ty: usize = img.height - 1 - row;
    return img.pixels.float32[ty * img.width + tx];
}

const expect = std.testing.expect;

// test "open_texture" {
//     const io = @constCast(&Io.Threaded.init(std.testing.allocator, .{})).io();
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     const gpa = arena.allocator();
//     defer arena.deinit();
//
//     var image = try open_texture("tiger_uv.png", &arena, io);
//     defer image.deinit(gpa);
//     // print("h: {d} w: {d}\n", .{ image.height, image.width });
//
//     var i: usize = 0;
//     for (image.pixels.float32) |pixel| {
//         if (i == 10) break;
//         print("rgb: {any}\n", .{pixel});
//         i += 1;
//     }
// }

test "parse" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = @constCast(&Io.Threaded.init(std.testing.allocator, .{})).io();
    const file = try Io.Dir.cwd().openFile(io, "cube_t.obj", .{});

    var buf: [30 * 20]u8 = undefined;
    const read = try file.readPositionalAll(io, &buf, 0);
    const slice = buf[0..read];

    var vertices: [8 * 3]Vec3 = undefined;
    var faces: [12 * 3]usize = undefined;
    var uv: [vertices.len]Vec2 = undefined;
    var mesh_texts: [vertices.len]usize = undefined;
    const res = try parse_with_texture(slice, &faces, &vertices, &uv, &mesh_texts);

    // print("uv: {any}\n", .{res.uv});
    // print("faces: {any}\n", .{res.faces});
    // print("ts 0: {any}\n", .{res.uv[res.mesh_texts[0]]});
    // print("ts 1: {any}\n", .{res.uv[res.mesh_texts[1]]});
    // for (res.uv) |v| {
    //     print("uv: {}\n", .{v});
    // }

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
    try expect(std.mem.eql(usize, res.faces, &[_]usize{
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
        2, 7, 6, // i 33 + 3 = 36
        2, 6, 3, // i 36
    }));
}
