const std = @import("std");
const Io = std.Io;
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
    const ix: f32 = 10;
    const iy: f32 = 5;
    const z: f32 = 1.0;
    const z2: f32 = 6.0;

    const faces = [_]Coord3{
        // front
        Coord3{ .x = ix, .y = iy, .z = z },
        Coord3{ .x = -ix, .y = iy, .z = z },
        Coord3{ .x = ix, .y = -iy, .z = z },
        Coord3{ .x = -ix, .y = -iy, .z = z },
        // back
        Coord3{ .x = ix, .y = iy, .z = z2 },
        Coord3{ .x = -ix, .y = iy, .z = z2 },
        Coord3{ .x = ix, .y = -iy, .z = z2 },
        Coord3{ .x = -ix, .y = -iy, .z = z2 },
    };

    var a: f32 = 0;
    var dz: f32 = 0;

    while (true) {
        print("\x1b[2J\x1b[H", .{});
        @memset(buf, ' ');
        dz += 1 * dt;
        a += 0.3 * dt;

        for (faces) |face| {
            const i = coord_to_i(
                project(
                    // face,
                    rotate_xz(face, a),
                    // translate_z(face, dz),
                ),
                winsize.col,
                winsize.row,
            );
            buf[i] = '@';
        }

        writer.end = buf_len - 1;
        if (should_quit) break;
        try writer.flush();
        try init.io.sleep(
            Io.Duration.fromMilliseconds(ms_to_sleep),
            Io.Clock.boot,
        );
    }
    // show cursor, clear screen, place cursor at the top
    print("\x1b[2J\x1b[H\x1b[?25h", .{});
}

fn coord_to_i(c: Coord2, cols: u16, rows: u16) usize {
    const cols_i: isize = @intCast(cols);
    const rows_i: isize = @intCast(rows);
    const cy: isize = @trunc(c.y);
    const cx: isize = @trunc(c.x);
    const idx = (@divTrunc(rows_i, 2) - cy) * cols_i + (@divTrunc(cols_i, 2) + cx);
    return @intCast(std.math.clamp(idx, 0, cols_i * rows_i - 1));
}

fn project(c: Coord3) Coord2 {
    return .{ .x = c.x / c.z, .y = c.y / c.z };
}

fn translate_z(c: Coord3, dz: f32) Coord3 {
    return .{ .x = c.x, .y = c.y, .z = c.z + dz };
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

const expect = std.testing.expect;
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
    const r = coord_to_i(.{ .x = cols - 1, .y = rows - 1 }, cols, rows);
    try expect(r == 0);
}

test "coord_to_i_3" {
    const cols = 10;
    const rows = 10;
    const r = coord_to_i(.{ .x = -cols, .y = -rows }, cols, rows);
    try expect(r == 99);
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
    // monotonicity: same point, larger z → smaller projected magnitude
    const near = project(.{ .x = 10.0, .y = 5.0, .z = 1.0 });
    const far = project(.{ .x = 10.0, .y = 5.0, .z = 10.0 });
    try expect(@abs(far.x) < @abs(near.x));
    try expect(@abs(far.y) < @abs(near.y));

    // and the exact value at z = 10
    try expect(far.x == 1.0);
    try expect(far.y == 0.5);
}
