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

    const mesh = [_]@Vector(3, f32){
        // back
        .{ 1, 1, 1 },
        .{ -1, 1, 1 },
        .{ -1, -1, 1 },
        .{ 1, -1, 1 },
        // front
        .{ 1, 1, -1 },
        .{ -1, 1, -1 },
        .{ -1, -1, -1 },
        .{ 1, -1, -1 },
    };
    const fs = [2][12]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3 },
        .{ 1, 2, 3, 0, 5, 6, 7, 4, 4, 5, 6, 7 },
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

fn coord_to_i(c: @Vector(2, f32), cols: u16, rows: u16) ?usize {
    const cols_i: isize = @intCast(cols);
    const rows_i: isize = @intCast(rows);
    const cy: isize = @trunc(c[1]);
    const cx: isize = @trunc(c[0]);
    const row = @divTrunc(rows_i, 2) - cy;
    const col = @divTrunc(cols_i, 2) + cx;
    if (row < 0 or row >= rows_i) return null;
    if (col < 0 or col >= cols_i) return null;
    return @intCast(row * cols_i + col);
}

fn project(c: @Vector(3, f32)) @Vector(2, f32) {
    return .{ c[0] / c[2], c[1] / c[2] };
}

fn move_z(c: @Vector(3, f32)) @Vector(3, f32) {
    const d: f32 = 5;
    return .{ c[0], c[1], c[2] + d };
}

fn rotate_xz(c: @Vector(3, f32), a: f32) @Vector(3, f32) {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ c[0] * cos - c[2] * sin, c[1], c[0] * sin + c[2] * cos };
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
        const row = half_rows - @as(isize, @intFromFloat(@round(
            p0[1] + ii * stepY,
        )));
        const col = half_cols + @as(isize, @intFromFloat(@round(
            p0[0] + ii * stepX,
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
            @Vector(2, f32){ -10, 10 },
            @Vector(2, f32){ 10, -10 },
            &buf,
            cols,
            rows,
        );
    }

    const took = now.untilNow(io, clock);
    print("took: {}ms\n", .{took.toMilliseconds()});
}

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
