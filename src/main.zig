const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;

const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000.0 / @as(f32, fps)));
const dt: f32 = 1.0 / @as(f32, fps);

// hide cursor \x1b[?25l
// show l -> h

// clear screen and put cursor at top left
// "\x1b[2J\x1b[H"

// writes hello at the same position if called in a loop
// \x1b[Hhello

var should_quit = false;

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    should_quit = true;
}

const Coord3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Coord2 = struct {
    x: f32,
    y: f32,
};

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
    const buf = try arena.alloc(u8, winsize.col * winsize.row);
    const buf_len = buf.len;
    @memset(buf, ' ');
    var _writer: Io.File.Writer = .init(
        stdout,
        init.io,
        buf,
    );
    const writer = &_writer.interface;

    const mesh = [_]Coord3{
        // back
        .{ .x = 1, .y = 1, .z = 1 },
        .{ .x = -1, .y = 1, .z = 1 },
        .{ .x = -1, .y = -1, .z = 1 },
        .{ .x = 1, .y = -1, .z = 1 },
        // front
        .{ .x = 1, .y = 1, .z = -1 },
        .{ .x = -1, .y = 1, .z = -1 },
        .{ .x = -1, .y = -1, .z = -1 },
        .{ .x = 1, .y = -1, .z = -1 },
    };
    const fs = [6][]const u8{
        &[_]u8{ 0, 1, 2, 3 },
        &[_]u8{ 4, 5, 6, 7 },
        &[_]u8{ 0, 4 },
        &[_]u8{ 1, 5 },
        &[_]u8{ 2, 6 },
        &[_]u8{ 3, 7 },
    };

    var a: f32 = 0;
    const world_space: f32 = 5.0;
    const scale: f32 = @as(f32, @floatFromInt(winsize.col)) / 1.1;

    while (true) {
        if (should_quit) break;
        print("\x1b[2J\x1b[H", .{});
        @memset(buf, ' ');
        a = @mod(a + 2.0 * dt, std.math.tau);

        for (fs) |f| {
            for (f, 0..f.len) |vertex, i| {
                // _ = vertex;
                // const vec = mesh[f[i]];
                const vec = mesh[vertex];
                var r = rotate_xz(vec, a);
                r.z += world_space;

                var p = project(r);
                p.x *= scale;
                p.y *= scale * 0.5; // cells are 2x taller than wide

                // if (coord_to_i(p, winsize.col, winsize.row)) |buf_i| {
                //     buf[buf_i] = '@';
                // }

                // draw lines
                // const next = mesh[(i + 1) % mesh.len];
                const next = mesh[f[(i + 1) % f.len]];
                var rr = rotate_xz(next, a);
                rr.z += world_space;
                var pp = project(rr);
                pp.x *= scale;
                pp.y *= scale * 0.5;
                draw_line(p, pp, buf, winsize.col, winsize.row);
            }
        }

        writer.end = buf_len - 1;
        try writer.flush();
        try init.io.sleep(
            Io.Duration.fromMilliseconds(ms_to_sleep),
            Io.Clock.boot,
        );
    }

    // show cursor, clear screen, place cursor at the top
    print("\x1b[2J\x1b[H\x1b[?25h", .{});
}

fn coord_to_i(c: Coord2, cols: u16, rows: u16) ?usize {
    const cols_i: isize = @intCast(cols);
    const rows_i: isize = @intCast(rows);
    const cy: isize = @trunc(c.y);
    const cx: isize = @trunc(c.x);
    const row = @divTrunc(rows_i, 2) - cy;
    const col = @divTrunc(cols_i, 2) + cx;
    if (row < 0 or row >= rows_i) return null;
    if (col < 0 or col >= cols_i) return null;
    return @intCast(row * cols_i + col);
}

fn project(c: Coord3) Coord2 {
    return .{ .x = c.x / c.z, .y = c.y / c.z };
}

fn rotate_xz(c: Coord3, a: f32) Coord3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{
        .x = c.x * cos - c.z * sin,
        .y = c.y,
        .z = c.x * sin + c.z * cos,
    };
}

/// Draw line calculating slope and diffs
fn draw_line(p0: Coord2, p1: Coord2, buf: []u8, cols: u16, rows: u16) void {
    // -1 or 1
    const dx = p1.x - p0.x;
    const dy = p1.y - p0.y;
    const step: f32 = @max(@abs(dx), @abs(dy));
    const step_u: usize = @trunc(@max(@abs(dx), @abs(dy)));

    if (step > 0) {
        const stepX = dx / step;
        const stepY = dy / step;
        for (0..step_u + 1) |i| {
            const ii = @as(f32, @floatFromInt(i));
            const x: f32 = @round(p0.x + ii * stepX);
            const y: f32 = @round(p0.y + ii * stepY);
            buf[
                coord_to_i(
                    .{ .x = x, .y = y },
                    cols,
                    rows,
                ).?
            ] = '.';
            // print("x: {d} y: {d}\n", .{ x, y });
        }
    }
}

const expect = std.testing.expect;

// test "draw_line_1" {
//     const r = draw_line(
//         .{ .x = -2.0, .y = 2.0 },
//         .{ .x = 2.0, .y = 2.0 },
//     );
//     _ = r;
// }

test "coord_to_i_1" {
    const cols = 100;
    const rows = 50;
    const center = (rows / 2) * cols + (cols / 2);
    try expect(
        coord_to_i(.{ .x = 0, .y = 0 }, cols, rows) == center,
    );
}

test "coord_to_i_2" {
    const cols = 100;
    const rows = 50;
    const r = coord_to_i(.{ .x = 49, .y = -24 }, cols, rows);
    try expect(r != null);
    try expect(r.? == 49 * 100 + 99);
}

test "coord_to_i_3" {
    // out of bounds in every direction is null
    const cols = 10;
    const rows = 10;
    try expect(coord_to_i(.{ .x = 100, .y = 0 }, cols, rows) == null);
    try expect(coord_to_i(.{ .x = -100, .y = 0 }, cols, rows) == null);
    try expect(coord_to_i(.{ .x = 0, .y = 100 }, cols, rows) == null);
    try expect(coord_to_i(.{ .x = 0, .y = -100 }, cols, rows) == null);
}

test "project_z1_is_identity" {
    // at z = 1 the divide does nothing; x, y pass through
    const r = project(.{ .x = 10.0, .y = 5.0, .z = 1.0 });
    try expect(r.x == 10.0);
    try expect(r.y == 5.0);
}

test "project_z2_halves" {
    // at twice the distance, the object is half as big on screen
    const r = project(.{ .x = 10.0, .y = 5.0, .z = 2.0 });
    try expect(r.x == 5.0);
    try expect(r.y == 2.5);
}

test "project_farther_is_smaller" {
    const near = project(.{ .x = 10.0, .y = 5.0, .z = 1.0 });
    const far = project(.{ .x = 10.0, .y = 5.0, .z = 10.0 });
    try expect(@abs(far.x) < @abs(near.x));
    try expect(@abs(far.y) < @abs(near.y));

    try expect(far.x == 1.0);
    try expect(far.y == 0.5);
}
