const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;

const line_char = '*';
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000.0 / @as(f32, fps)));
const dt: f32 = 1.0 / @as(f32, fps);

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
    const fs = [2][12]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3 },
        .{ 1, 2, 3, 0, 5, 6, 7, 4, 4, 5, 6, 7 },
    };

    var a: f32 = 0;
    const scale_: f32 = @as(f32, @floatFromInt(winsize.col)) * 1.3;
    var out: [mesh.len]Coord2 = undefined;

    while (!should_quit) {
        @memset(buf, ' ');
        a = @mod(a + 1.0 * dt, std.math.tau);

        inline for (mesh, 0..) |v, i| {
            out[i] = project(scale(move_z(rotate_xz(v, a)), scale_));
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

fn scale(c: Coord3, s: f32) Coord3 {
    return .{
        .x = c.x * s,
        .y = c.y * s * 0.5,
        .z = c.z,
    };
}

fn move_z(c: Coord3) Coord3 {
    const d: f32 = 5;
    return .{
        .x = c.x,
        .y = c.y,
        .z = c.z + d,
    };
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
    if (step == 0) return;

    const stepX = dx / step;
    const stepY = dy / step;

    const half_cols = @divTrunc(cols, 2);
    const half_rows = @divTrunc(rows, 2);

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = half_rows - @as(isize, @intFromFloat(@round(
            p0.y + ii * stepY,
        )));
        const col = half_cols + @as(isize, @intFromFloat(@round(
            p0.x + ii * stepX,
        )));
        if (row >= 0 and row < rows and col >= 0 and col < cols) {
            buf[@intCast(row * cols + col)] = line_char;
        }
    }
}

const expect = std.testing.expect;

test "bench_draw_line" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();
    defer threaded.deinit();
    const clock = Io.Clock.boot;
    const cols = 100;
    const rows = 50;
    var buf: [cols * rows]u8 = @splat(' ');
    const now = clock.now(io);

    for (0..1_000_000) |_| {
        draw_line(
            Coord2{ .x = -10, .y = 10 },
            Coord2{ .x = 10, .y = -10 },
            &buf,
            cols,
            rows,
        );
    }

    const took = now.untilNow(io, clock);
    print("took: {}ms\n", .{took.toMilliseconds()});

    std.mem.doNotOptimizeAway(&buf);
}

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

// hide cursor \x1b[?25l
// show l -> h

// clear screen and put cursor at top left
// "\x1b[2J\x1b[H"

// writes hello at the same position if called in a loop
// \x1b[Hhello
