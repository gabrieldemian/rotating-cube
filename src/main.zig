const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;

const line_char = '*';
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000.0 / @as(f32, fps)));
const dt: f32 = 1.0 / @as(f32, fps);

const camera = @Vector(3, f32){ 0, 0, 0 };

var should_quit = false;

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
    const mesh = [8]@Vector(3, f32){
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
    const fs = [2][12]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3 },
        .{ 1, 2, 3, 0, 5, 6, 7, 4, 5, 4, 7, 6 },
    };
    const tris = [12][3]u8{
        .{ 0, 1, 2 }, .{ 0, 2, 3 }, // back   (+z)
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, // front  (−z)
        .{ 0, 3, 6 }, .{ 0, 6, 5 }, // right  (+x)
        .{ 1, 4, 7 }, .{ 1, 7, 2 }, // left   (−x)
        .{ 1, 0, 5 }, .{ 1, 5, 4 }, // top    (+y)
        .{ 2, 7, 6 }, .{ 2, 6, 3 }, // bottom (−y)
    };

    var a: f32 = 0;
    const scalar = @as(f32, @floatFromInt(winsize.col)) * 1.3;
    const scale = @Vector(3, f32){ scalar, scalar * 0.5, 1 };
    var out: [mesh.len]@Vector(2, f32) = undefined;

    while (!should_quit) {
        @memset(buf, ' ');
        a = @mod(a + 1.0 * dt, std.math.tau);

        inline for (mesh, 0..) |v, i| {
            out[i] = project(scale * move_z(rotate_xz(v, a)));
        }

        for (0..tris.len) |i| {
            if (!cull(tris[i], tris[i + 1], tris[i + 2]) <= 0) {
                continue;
            }
            i += 2;
        }

        inline for (fs[0], fs[1]) |v1, v2| {
            draw_line(
                out[v1],
                out[v2],
                buf,
                winsize.col,
                winsize.row,
            );
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

fn coord_to_i(v: @Vector(2, f32), cols: u16, rows: u16) ?usize {
    const cols_i: isize = @intCast(cols);
    const rows_i: isize = @intCast(rows);
    const cy: isize = @trunc(v[1]);
    const cx: isize = @trunc(v[0]);
    const row = @divTrunc(rows_i, 2) - cy;
    const col = @divTrunc(cols_i, 2) + cx;
    if (row < 0 or row >= rows_i) return null;
    if (col < 0 or col >= cols_i) return null;
    return @intCast(row * cols_i + col);
}

/// Returns true if the triangle is visible.
fn cull(v0: @Vector(3, f32), v1: @Vector(3, f32), v2: @Vector(3, f32)) bool {
    const n = norm(cross(v1 - v0, v2 - v0));
    const cen = (v0 + v1 + v2) / @as(@Vector(3, f32), @splat(3));
    return dot(n, norm(camera - cen)) > 0;
}

fn project(v: @Vector(3, f32)) @Vector(2, f32) {
    return .{ v[0] / v[2], v[1] / v[2] };
}

fn move_z(v: @Vector(3, f32)) @Vector(3, f32) {
    const d: f32 = 5;
    return .{ v[0], v[1], v[2] + d };
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

/// Draw line calculating slope and diffs
fn draw_line(
    p0: @Vector(2, f32),
    p1: @Vector(2, f32),
    buf: []u8,
    cols: u16,
    rows: u16,
) void {
    // -1 or 1
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const step: f32 = @max(@abs(dx), @abs(dy));
    if (step == 0) return;

    const stepX = dx / step;
    const stepY = dy / step;

    const half_cols = @divTrunc(cols, 2);
    const half_rows = @divTrunc(rows, 2);

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = half_rows - @as(isize, @trunc(@round(
            p0[1] + ii * stepY,
        )));
        const col = half_cols + @as(isize, @trunc(@round(
            p0[0] + ii * stepX,
        )));
        if (row >= 0 and row < rows and col >= 0 and col < cols) {
            buf[@intCast(row * cols + col)] = line_char;
        }
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

// test "bench_draw_line" {
//     const gpa = std.testing.allocator;
//     var threaded: std.Io.Threaded = .init(gpa, .{});
//     const io = threaded.io();
//     defer threaded.deinit();
//     const clock = Io.Clock.boot;
//     const cols = 100;
//     const rows = 50;
//     var buf: [cols * rows]u8 = @splat(' ');
//     const now = clock.now(io);
//     for (0..1_000_000) |_| {
//         draw_line(
//             @Vector(2, f32){ -10, 10 },
//             @Vector(2, f32){ 10, -10 },
//             &buf,
//             cols,
//             rows,
//         );
//     }
//     const took = now.untilNow(io, clock);
//     print("took: {}ms\n", .{took.toMilliseconds()});
// }

test "coord_to_i_1" {
    const cols = 100;
    const rows = 50;
    const center = (rows / 2) * cols + (cols / 2);
    try expect(
        coord_to_i(.{ 0, 0 }, cols, rows) == center,
    );
}

test "coord_to_i_2" {
    const cols = 100;
    const rows = 50;
    const r = coord_to_i(.{ 49, -24 }, cols, rows);
    try expect(r != null);
    try expect(r.? == 49 * 100 + 99);
}

test "coord_to_i_3" {
    // out of bounds in every direction is null
    const cols = 10;
    const rows = 10;
    try expect(coord_to_i(.{ 100, 0 }, cols, rows) == null);
    try expect(coord_to_i(.{ -100, 0 }, cols, rows) == null);
    try expect(coord_to_i(.{ 0, 100 }, cols, rows) == null);
    try expect(coord_to_i(.{ 0, -100 }, cols, rows) == null);
}

test "project_z1_is_identity" {
    // at z = 1 the divide does nothing; x, y pass through
    const r = project(.{ 10.0, 5.0, 1.0 });
    try expect(r[0] == 10.0);
    try expect(r[1] == 5.0);
}

test "project_z2_halves" {
    // at twice the distance, the object is half as big on screen
    const r = project(.{ 10.0, 5.0, 2.0 });
    try expect(r[0] == 5.0);
    try expect(r[1] == 2.5);
}

test "project_farther_is_smaller" {
    const near = project(.{ 10.0, 5.0, 1.0 });
    const far = project(.{ 10.0, 5.0, 10.0 });
    try expect(@abs(far[0]) < @abs(near[0]));
    try expect(@abs(far[1]) < @abs(near[1]));
    try expect(far[0] == 1.0);
    try expect(far[1] == 0.5);
}

// hide cursor \x1b[?25l
// show l -> h

// clear screen and put cursor at top left
// "\x1b[2J\x1b[H"

// writes hello at the same position if called in a loop
// \x1b[Hhello
