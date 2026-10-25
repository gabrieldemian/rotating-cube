const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;

const line_char = '*';
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000.0 / @as(f32, fps)));
const dt: f32 = 1.0 / @as(f32, fps);
const camera = @Vector(3, f32){ 0, 0, 0 };
const fov = math.pi / 3.0; // 60 degrees

var should_quit = false;
var bufe: [1024][2]f32 = undefined;

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    should_quit = true;
}

pub fn main(init: std.process.Init) !void {
    const mask: std.posix.sigset_t = std.mem.zeroes(std.posix.sigset_t);

    const action = std.posix.Sigaction{
        .flags = 0,
        .mask = mask,
        .handler = .{ .handler = handleSigInt },
    };

    std.posix.sigaction(std.posix.SIG.INT, &action, null);

    // hide cursor
    print("\x1b[?25l", .{});

    var winsize: std.posix.winsize = undefined;
    const stdout = Io.File.stdout();

    _ = std.posix.system.ioctl(
        stdout.handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );

    const arena: std.mem.Allocator = init.arena.allocator();
    // extra 3 for clear ANSI
    var buf_ = try arena.alloc(u8, winsize.col * winsize.row + 3);
    buf_[0] = '\x1b';
    buf_[1] = '[';
    buf_[2] = 'H';
    const buf = buf_[3..];
    @memset(buf, ' ');
    var _writer: Io.File.Writer = .init(
        stdout,
        init.io,
        buf_,
    );
    const writer = &_writer.interface;

    // counter clockwise vertices
    const mesh = [_]@Vector(3, f32){
        // back
        .{ 1, 1, 1 }, // top-right
        .{ -1, 1, 1 }, //  top-left
        .{ -1, -1, 1 }, //  bottom-left
        .{ 1, -1, 1 }, //  bottom-right
        // front
        .{ -1, 1, -1 }, // top-right
        .{ 1, 1, -1 }, // top-left
        .{ 1, -1, -1 }, // bottom-left
        .{ -1, -1, -1 }, // bottom-right
    };
    const tris = [_][3]u8{
        .{ 0, 1, 2 }, .{ 0, 2, 3 }, // back   (+z)
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, // front  (−z)
        .{ 0, 3, 6 }, .{ 0, 6, 5 }, // right  (+x)
        .{ 1, 4, 7 }, .{ 1, 7, 2 }, // left   (−x)
        .{ 1, 0, 5 }, .{ 1, 5, 4 }, // top    (+y)
        .{ 2, 7, 6 }, .{ 2, 6, 3 }, // bottom (−y)
    };

    var a: f32 = 0;
    const scalar = @as(f32, @floatFromInt(winsize.col)) * 0.8;
    const scale = @Vector(3, f32){ scalar, scalar * 0.5, 1 };
    var out: [mesh.len]@Vector(3, f32) = undefined;

    while (!should_quit) {
        @memset(buf, ' ');
        a = @mod(a + 1.0 * dt, std.math.tau);

        inline for (mesh, 0..) |v, i| {
            out[i] = scale * move_z(rotate_xz(v, a));
        }

        for (tris) |t| {
            const t0 = out[t[0]];
            const t1 = out[t[1]];
            const t2 = out[t[2]];
            if (cull(t0, t1, t2)) {
                _ = rasterize(
                    weak_project(t0),
                    weak_project(t1),
                    weak_project(t2),
                    buf,
                    winsize.col,
                    winsize.row,
                );
                continue;
            }
        }

        writer.end = buf_.len - 1;
        try writer.flush();
        try init.io.sleep(
            Io.Duration.fromMilliseconds(ms_to_sleep),
            Io.Clock.boot,
        );
    }

    // show cursor, clear screen, place cursor at the top
    print("\x1b[2J\x1b[H\x1b[?25h", .{});
}

// fn coord_to_i(v: @Vector(2, f32), cols: u16) usize {
//     return @intCast(v[1] * cols + v[0]);
// }

/// Returns true if the triangle is visible.
fn cull(v0: @Vector(3, f32), v1: @Vector(3, f32), v2: @Vector(3, f32)) bool {
    if (v0[2] <= 0.1 or v1[2] <= 0.1 or v2[2] <= 0.1) return false;
    const n = norm(cross(v1 - v0, v2 - v0));
    const cen = (v0 + v1 + v2) / @as(@Vector(3, f32), @splat(3));
    return dot(n, norm(camera - cen)) > 0;
}

// equivalent to  fov = 90° and aspect = 1
fn weak_project(v: @Vector(3, f32)) @Vector(2, f32) {
    return .{ v[0] / v[2], v[1] / -v[2] };
}

fn move_z(v: @Vector(3, f32)) @Vector(3, f32) {
    const d: f32 = -5;
    return .{ v[0], v[1], v[2] - d };
}

fn rotate_xz(v: @Vector(3, f32), a: f32) @Vector(3, f32) {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos - v[2] * sin, v[1], v[0] * sin + v[2] * cos };
}

fn rotate_x(v: @Vector(3, f32), a: f32) @Vector(3, f32) {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos - v[2] * sin, v[1], v[2] };
}

/// Draw line calculating slope and diffs.
/// Assumes the line is visible.
fn draw_line(
    v0: @Vector(2, f32),
    v1: @Vector(2, f32),
    cols: u16,
    rows: u16,
    buf: []u8,
    buf1: ?[][2]f32,
) usize {
    // -1 or 1
    const dx = v1[0] - v0[0];
    const dy = v1[1] - v0[1];
    const step: f32 = @max(@abs(dx), @abs(dy));
    if (step == 0) return 0;

    const stepX = dx / step;
    const stepY = dy / step;

    const half_cols: u16 = @divTrunc(cols, 2);
    const half_rows: u16 = @divTrunc(rows, 2);
    var count: usize = 0;

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = half_rows - @as(isize, @trunc(@round(
            v0[1] + ii * stepY,
        )));
        const col = half_cols + @as(isize, @trunc(@round(
            v0[0] + ii * stepX,
        )));
        if (row >= 0 and row < rows and col >= 0 and col < cols) {
            buf[@intCast(row * cols + col)] = line_char;
            if (buf1) |asd| {
                asd[i] = .{ v0[0] + ii * stepX, v0[1] + ii * stepY };
                count += 1;
            }
        }
    }

    return count;
}

fn rasterize(
    v0: @Vector(2, f32),
    v1: @Vector(2, f32),
    v2: @Vector(2, f32),
    buf: []u8,
    cols: u16,
    rows: u16,
) void {
    var len: usize = 0;
    len += draw_line(v0, v1, cols, rows, buf, bufe[len..]);
    len += draw_line(v1, v2, cols, rows, buf, bufe[len..]);
    len += draw_line(v2, v0, cols, rows, buf, bufe[len..]);

    const b = bufe[0..len];

    std.mem.sortUnstable([2]f32, b, {}, struct {
        fn lessThan(_: void, lhs: [2]f32, rhs: [2]f32) bool {
            const l = @round(lhs[1]);
            const r = @round(rhs[1]);
            if (l != r) return l < r;
            return lhs[0] < rhs[0];
        }
    }.lessThan);

    // edges are sorted by Y like this
    // (0,0) (1,0) (2,0) (3,1) (4,1) (7,1)
    var first_i: usize = 0;
    while (first_i < b.len) {
        const row_key = @round(b[first_i][1]);
        var last_i: usize = first_i + 1;
        // only draw first and last X of the same Y.
        while (last_i < b.len and @round(b[last_i][1]) == row_key) {
            last_i += 1;
        }
        _ = draw_line(
            @as(@Vector(2, f32), b[first_i]),
            @as(@Vector(2, f32), b[last_i - 1]),
            cols,
            rows,
            buf,
            null,
        );
        first_i = last_i;
    }
}

/// |v|
fn magnitude(v: anytype) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

/// a · b
fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

/// a × b
fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// Normalize vector `v`
fn norm(v: anytype) @TypeOf(v) {
    return v / @as(@TypeOf(v), @splat(magnitude(v)));
}

const expect = std.testing.expect;

test "cull" {
    // front triangle
    const a = @Vector(3, f32){ -3, 3, 5 };
    const b = @Vector(3, f32){ 3, 3, 5 };
    const c = @Vector(3, f32){ 3, -3, 5 };
    try expect(cull(a, b, c));
}

test "cull_2" {
    // back triangle
    const a = @Vector(3, f32){ 3, 3, 5 };
    const b = @Vector(3, f32){ -3, 3, 5 };
    const c = @Vector(3, f32){ -3, -3, 5 };
    try expect(!cull(a, b, c));
    // rotated back triangle -> front triangle
    try expect(cull(
        rotate_x(a, math.pi),
        rotate_x(b, math.pi),
        rotate_x(c, math.pi),
    ));
}

test "cross" {
    const a = @Vector(3, f32){ 2, 3, 4 };
    const b = @Vector(3, f32){ 5, 6, 7 };
    const c = cross(a, b);
    try expect(c[0] == -3);
    try expect(c[1] == 6);
    try expect(c[2] == -3);
}

test "normalize" {
    const v = @Vector(3, f32){ 10, 10, 10 };
    const n = norm(v);
    // a normalized vector has a length of ~1
    const sum = @reduce(.Add, n * n);
    try expect(sum > 0.999999 and sum < 1.000001);
    try expect(n[0] == 0.57735026);
    try expect(n[1] == 0.57735026);
    try expect(n[2] == 0.57735026);
}

test "magnitude" {
    const v = @Vector(3, f32){ 10, 10, 10 };
    const vlen = magnitude(v);
    try expect(vlen == 17.320509);
}

test "dot_product" {
    const a = @Vector(2, f32){ -12, 16 };
    const b = @Vector(2, f32){ 12, 9 };
    const d = dot(a, b);
    try expect(d == 0);
}

test "dot_product_1" {
    const a = @Vector(3, f32){ 0, 0, -1 };
    const b = @Vector(3, f32){ 0, 0, -1 };
    const d = dot(a, b);
    // same direction
    try expect(d == 1);
}

test "dot_product_2" {
    const a = @Vector(3, f32){ 0, 0, -1 };
    const b = @Vector(3, f32){ 0, 0, 1 };
    const d = dot(a, b);
    // pointing to each other (opposite directions)
    try expect(d == -1);
}

// hide cursor \x1b[?25l
// show l -> h

// clear screen and put cursor at top left
// "\x1b[2J\x1b[H"

// writes hello at the same position if called in a loop
// \x1b[Hhello
