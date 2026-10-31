const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;
const posix = std.posix;

const Vec2 = @Vector(2, f32);
const Vec3 = @Vector(3, f32);

/// Units per second
const move_per_key = 0.2;
const angle_per_key = 0.1;
const line_char: u8 = '#';
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000 / @as(f32, fps)));
const camera = Vec3{ 0, 0, 0 };
const fov: f32 = math.pi / 3.0;
const cell_size = 6;

var cols: u16 = 50;
var rows: u16 = 50;
var should_quit = false;
var bufe: [1024][2]f32 = undefined;
var fpsbuf: [6]u8 = undefined;
// terminal only sends 1 char at a time,
// TODO: support kitty keyboard protocol
var stdinbuf: [1]u8 = undefined;

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

    // show cursor, clear screen, place cursor at the top,
    // remove kitty keyboard protocol flag
    defer print("\x1b[2J\x1b[H\x1b[?25h\x1b[<u", .{});

    const stdout = Io.File.stdout();
    const stdin = Io.File.stdin();
    var winsize: std.posix.winsize = undefined;
    _ = std.posix.system.ioctl(
        stdout.handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    cols = winsize.col;
    rows = winsize.row;

    const arena: std.mem.Allocator = init.arena.allocator();
    // extra 3 for clear ANSI
    // extra 6 for color codes
    var buf_ = try arena.alloc(
        u8,
        (winsize.col * @as(usize, winsize.row) * cell_size) + 3,
    );
    buf_[0..3].* = [3]u8{ 0x1b, '[', 'H' };
    const buf = buf_[3..];

    var _writer: Io.File.Writer = .init(
        stdout,
        init.io,
        buf_,
    );
    const writer = &_writer.interface;

    // counter clockwise vertices.
    // right hand coordinates.
    const mesh = [_]Vec3{
        // front
        .{ 1, 1, 1 }, // top-right
        .{ -1, 1, 1 }, //  top-left
        .{ -1, -1, 1 }, //  bottom-left
        .{ 1, -1, 1 }, //  bottom-right
        // back
        .{ -1, 1, -1 }, // top-right
        .{ 1, 1, -1 }, // top-left
        .{ 1, -1, -1 }, // bottom-left
        .{ -1, -1, -1 }, // bottom-right
    };
    const tris = [_][3]u8{
        .{ 0, 1, 2 }, .{ 0, 2, 3 },
        .{ 4, 5, 6 }, .{ 4, 6, 7 },
        .{ 0, 3, 6 }, .{ 0, 6, 5 },
        .{ 1, 4, 7 }, .{ 1, 7, 2 },
        .{ 1, 0, 5 }, .{ 1, 5, 4 },
        .{ 2, 7, 6 }, .{ 2, 6, 3 },
    };

    const terminal_scale = Vec2{ 1, 0.5 };
    const aspect =
        @as(f32, @floatFromInt(winsize.col)) /
        @as(f32, @floatFromInt(winsize.row));

    const clock = std.Io.Clock.boot;
    var last = clock.now(init.io);
    var frames: u32 = 0;
    var fps_ns: u32 = 0;

    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.iflag.IXON = false;
    raw.cc[@backingInt(posix.V.MIN)] = 0;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
    defer posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};

    var last_fps: u64 = 0;
    var translate: Vec3 = .{ 0, 0, -3.5 };
    var yaw_a: f32 = 0;
    var pitch_a: f32 = 0;
    var out: [mesh.len]Vec3 = undefined;
    var a: f32 = 0;

    while (!should_quit) {
        const fr_until_now = last.untilNow(init.io, clock);
        const dt = @as(f32, @floatFromInt(fr_until_now.toNanoseconds())) /
            1_000_000_000;
        const now = clock.now(init.io);
        last = now;

        for (0..@as(usize, winsize.row) * winsize.col) |i| {
            put_cell(buf, i, ' ');
        }

        put_cell(buf, (winsize.col * winsize.row) - 3, 'F');
        put_cell(buf, (winsize.col * winsize.row) - 2, 'P');
        put_cell(buf, (winsize.col * winsize.row) - 1, 'S');
        a += 1.0 * dt;

        inline for (mesh, 0..) |v, i| {
            out[i] = pitch(yaw(v + translate, -yaw_a), -pitch_a);
        }

        const inread = stdin.readStreaming(
            init.io,
            &[_][]u8{&stdinbuf},
        ) catch |e| switch (e) {
            error.WouldBlock => 0,
            error.EndOfStream => 0,
            else => return e,
        };
        if (inread > 0) {
            const keys = stdinbuf[0..inread];
            const d = move_per_key;
            for (keys) |key| {
                switch (key) {
                    // move
                    'w' => translate += yaw(Vec3{ 0, 0, d }, yaw_a),
                    'a' => translate += yaw(Vec3{ d, 0, 0 }, yaw_a),
                    's' => translate += yaw(Vec3{ 0, 0, -d }, yaw_a),
                    'd' => translate += yaw(Vec3{ -d, 0, 0 }, yaw_a),
                    'q' => translate += Vec3{ 0, d, 0 },
                    ' ' => translate += Vec3{ 0, -d, 0 },
                    'h' => yaw_a += angle_per_key,
                    'l' => yaw_a -= angle_per_key,
                    'j' => pitch_a -= angle_per_key,
                    'k' => pitch_a += angle_per_key,
                    else => {},
                }
            }
        }

        for (tris) |t| {
            const t0 = out[t[0]];
            const t1 = out[t[1]];
            const t2 = out[t[2]];
            if (is_visible(t0, t1, t2)) {
                _ = rasterize(
                    screen_space(project(t0, aspect) * terminal_scale),
                    screen_space(project(t1, aspect) * terminal_scale),
                    screen_space(project(t2, aspect) * terminal_scale),
                    buf,
                );
                continue;
            }
        }

        frames += 1;
        fps_ns += @intCast(fr_until_now.toNanoseconds());

        if (fps_ns >= 500) {
            last_fps = (frames * 1_000_000_000) / fps_ns;
            frames = 0;
            fps_ns = 0;
        }

        const num = try std.mem.print(&fpsbuf, "{d:0>6}", .{last_fps % 1000000});
        const total: usize = @as(usize, winsize.col) * winsize.row;
        for (num, 0..) |n, i| {
            put_cell(buf, total - num.len - 4 + i, n);
        }

        writer.end = buf_.len;
        try writer.flush();
        try init.io.sleep(
            Io.Duration.fromMilliseconds(ms_to_sleep),
            Io.Clock.boot,
        );
    }
}

/// Returns true if the triangle is visible.
fn is_visible(v0: Vec3, v1: @Vector(3, f32), v2: @Vector(3, f32)) bool {
    if (v0[2] >= -0.1 or v1[2] >= -0.1 or v2[2] >= -0.1) return false;
    const n = norm(cross(v1 - v0, v2 - v0));
    const cen = (v0 + v1 + v2) / @as(Vec3, @splat(3));
    return dot(n, norm(camera - cen)) > 0;
}

/// From NDC space to screen space
fn screen_space(ndc: Vec2) @Vector(2, f32) {
    const w: f32 = @floatFromInt(cols);
    const h: f32 = @floatFromInt(rows);
    return .{
        ndc[0] * w,
        ndc[1] * h,
    };
}

// equivalent to  fov = 90° and aspect = 1
fn weak_project(v: Vec3) Vec2 {
    return .{ v[0] / v[2], v[1] / -v[2] };
}

/// Project vector and return NDC
fn project(v: Vec3, a: f32) Vec2 {
    const near: f32 = 0.1;
    // const far = 10;

    const top = near * @tan(fov / 2);
    const bottom = -top;
    const right = top * a;
    const left = -right;

    const x1 =
        v[0] * (2 * near / (right - left)) +
        v[2] * (right + left) / (right - left);
    const y1 =
        v[1] * (2 * near) / (top - bottom) +
        v[2] * (top + bottom) / (top - bottom);
    // const z1 =
    //     v[2] * (far + near) / (near - far) +
    //     2 * far * near / (near - far);
    const w = -v[2];

    // clip space before the divide by w

    return .{
        x1 / w,
        y1 / w,
    };
}

fn move_z(v: Vec3, d: f32) Vec3 {
    return .{ v[0], v[1], v[2] + d };
}

/// Rotate around Y
fn yaw(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos + v[2] * sin, v[1], -v[0] * sin + v[2] * cos };
}

fn yaw_at(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos + v[2] * sin, v[1], -v[0] * sin + v[2] * cos };
}

/// Rotate around X
fn pitch(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0], v[1] * cos - v[2] * sin, v[1] * sin + v[2] * cos };
}

/// Rotate around Z
fn roll(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0] * cos - v[1] * sin, v[0] * sin + v[1] * cos, v[2] };
}

fn rotate_y(v: Vec3, a: f32) Vec3 {
    const sin = @sin(a);
    const cos = @cos(a);
    return .{ v[0], v[1] * cos - v[2] * sin, v[2] };
}

var cha = std.Random.DefaultPrng.init(0);
const rand = cha.random();

/// Draw line calculating slope and diffs.
fn draw_line(
    v0: Vec2,
    v1: Vec2,
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
        const row = half_rows - @as(isize, @round(
            v0[1] + ii * stepY,
        ));
        const col = half_cols + @as(isize, @round(
            v0[0] + ii * stepX,
        ));
        if (row >= 0 and row < rows and col >= 0 and col < cols) {
            const iii: usize = @intCast(row * cols + col);
            put_cell(buf, iii, line_char);
            if (buf1) |asd| {
                asd[i] = .{ v0[0] + ii * stepX, v0[1] + ii * stepY };
                count += 1;
            }
        }
    }

    return count;
}

fn rasterize(
    v0: Vec2,
    v1: Vec2,
    v2: Vec2,
    buf: []u8,
) void {
    var len: usize = 0;
    len += draw_line(v0, v1, buf, bufe[len..]);
    len += draw_line(v1, v2, buf, bufe[len..]);
    len += draw_line(v2, v0, buf, bufe[len..]);

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
            @as(Vec2, b[first_i]),
            @as(Vec2, b[last_i - 1]),
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
fn cross(a: Vec3, b: Vec3) Vec3 {
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

/// Put a logical cell `i` on the screen
fn put_cell(buf: []u8, i: usize, char: u8) void {
    if (cols == 0) return;
    const offset: usize = i * cell_size;
    if (offset > buf.len) return;
    buf[offset..][0..cell_size].* = .{ 0x1b, '[', '3', '4', 'm', char };
}

const expect = std.testing.expect;

test "cull" {
    // front triangle
    const a = move_z(Vec3{ 1, 1, 1 }, -3.5);
    const b = move_z(Vec3{ -1, 1, 1 }, -3.5);
    const c = move_z(Vec3{ -1, -1, 1 }, -3.5);
    try expect(is_visible(a, b, c));
}

test "cull_2" {
    // back triangle
    const a = Vec3{ -3, 3, -3 };
    const b = Vec3{ 3, 3, -3 };
    const c = Vec3{ 3, -3, -3 };
    try expect(!is_visible(a, b, c));

    // rotated back triangle -> front triangle
    //
    // either put them on the origin or just do a half
    // rotation and move towards the camera.
    //
    // const center = (a + b + c) / @as(Vec3, @splat(3));
    const move_to_camera = Vec3{ 1, 1, -3 };
    try expect(is_visible(
        yaw(a, math.pi) * move_to_camera,
        yaw(b, math.pi) * move_to_camera,
        yaw(c, math.pi) * move_to_camera,
    ));
}

test "cross" {
    const a = Vec3{ 2, 3, 4 };
    const b = Vec3{ 5, 6, 7 };
    const c = cross(a, b);
    try expect(c[0] == -3);
    try expect(c[1] == 6);
    try expect(c[2] == -3);
}

test "normalize" {
    const v = Vec3{ 10, 10, 10 };
    const n = norm(v);
    // a normalized vector has a length of ~1
    const sum = @reduce(.Add, n * n);
    try expect(sum > 0.999999 and sum < 1.000001);
    try expect(n[0] == 0.57735026);
    try expect(n[1] == 0.57735026);
    try expect(n[2] == 0.57735026);
}

test "magnitude" {
    const v = Vec3{ 10, 10, 10 };
    const vlen = magnitude(v);
    try expect(vlen == 17.320509);
}

test "dot_product" {
    const a = Vec2{ -12, 16 };
    const b = Vec2{ 12, 9 };
    const d = dot(a, b);
    try expect(d == 0);
}

test "dot_product_1" {
    const a = Vec3{ 0, 0, -1 };
    const b = Vec3{ 0, 0, -1 };
    const d = dot(a, b);
    // same direction
    try expect(d == 1);
}

test "dot_product_2" {
    const a = Vec3{ 0, 0, -1 };
    const b = Vec3{ 0, 0, 1 };
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

// true color
//
// background = 19 bytes
// \x1b[48;2;025;010;200mTRUECOLOR
//
// foreground
// \x1b[38;2;25;10;200mTRUECOLOR
//
// ";2" means
// 2 = direct color / RGB
// 5 = indexed palette index 0..255 color
// 3 = CMY
// 4 = CMYK
//
// ";38" means
