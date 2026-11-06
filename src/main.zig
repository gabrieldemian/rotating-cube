const std = @import("std");
const key = @import("key.zig");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;
const posix = std.posix;

const Vec2 = @Vector(2, f32);
const Vec3 = @Vector(3, f32);
const RGB = Vec3;

const move_per_sec = 5.0;
const line_char: u8 = '#';
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000 / @as(f32, fps)));
const camera = Vec3{ 0, 0, 0 };
const fov: f32 = math.pi / 3.0;
const cell_size = 20;

var cols: u16 = 1;
var rows: u16 = 1;
var half_cols: i32 = 0;
var half_rows: i32 = 0;
var should_quit = std.atomic.Value(bool).init(false);
var should_resize = std.atomic.Value(bool).init(false);
const buf_extra = 3;
pub var framebuf: [300 * 150 * cell_size + buf_extra]u8 = undefined;
var cleared_framebuf: [framebuf.len]u8 = undefined;
var stdinbuf: [100]u8 = undefined;
var winsize: posix.winsize = undefined;

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

fn handle_sigint(_: posix.SIG) callconv(.c) void {
    should_quit.store(true, .release);
}
fn handle_sigwinch(_: posix.SIG) callconv(.c) void {
    should_resize.store(true, .seq_cst);
}

fn resize(stdout: std.Io.File) void {
    _ = posix.system.ioctl(
        stdout.handle,
        posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    if (winsize.col != cols or winsize.row != rows) {
        cols = winsize.col;
        rows = winsize.row;
        half_cols = cols / 2;
        half_rows = rows / 2;
    }
}

pub fn main(init: std.process.Init) !void {
    const action_sigint = posix.Sigaction{
        .flags = 0,
        .mask = posix.sigemptyset(),
        .handler = .{ .handler = handle_sigint },
    };
    posix.sigaction(posix.SIG.INT, &action_sigint, null);
    const action_sigwinch = posix.Sigaction{
        .flags = 0,
        .mask = posix.sigemptyset(),
        .handler = .{ .handler = handle_sigwinch },
    };
    posix.sigaction(posix.SIG.WINCH, &action_sigwinch, null);

    const stdout = Io.File.stdout();
    const stdin = Io.File.stdin();
    resize(stdout);

    const toflush = [_]u8{
        0x1b, '[', '?', '2', '5', 'l', // hide cursor
        0x1b, '[', '>', '1', '0', 'u', // kitty keyboard protocol
    };
    try stdout.writeStreamingAll(init.io, &toflush);

    // show cursor, clear screen, place cursor at the top,
    // remove kitty keyboard protocol flag
    defer stdout.writeStreamingAll(init.io, "\x1b[2J\x1b[H\x1b[?25h\x1b[<u") catch {};

    framebuf[0..3].* = [3]u8{ 0x1b, '[', 'H' };
    var buf = framebuf[buf_extra..(@as(usize, cols) * rows * cell_size + buf_extra)];

    const terminal_scale = Vec2{ 1, 0.5 };
    var aspect = @as(f32, @floatFromInt(cols)) / @as(f32, @floatFromInt(rows));

    const clock = std.Io.Clock.boot;
    var last = clock.now(init.io);
    var frames: u64 = 0;
    var fps_ns: u32 = 0;

    // enter raw mode
    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.iflag.IXON = false;
    raw.cc[@backingInt(posix.V.MIN)] = 0;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
    defer posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};

    // state of the cube
    var translate: Vec3 = .{ 0, 0, -3.5 };
    var yaw_a: f32 = 0;
    var pitch_a: f32 = 0;
    var last_fps: u64 = 0;
    var out: [mesh.len]Vec3 = undefined;
    var curr_keys_down: packed struct(u10) {
        w: bool,
        a: bool,
        s: bool,
        d: bool,
        h: bool,
        j: bool,
        k: bool,
        l: bool,
        @" ": bool,
        q: bool,
    } = @fromBackingInt(0);

    var cleared = cleared_framebuf[0..buf.len];
    for (0..@as(usize, rows) * cols) |i| {
        put_clear_cell(cleared, i);
    }

    while (!should_quit.load(.acquire)) {
        if (should_resize.swap(false, .seq_cst)) {
            resize(stdout);
            buf = framebuf[buf_extra .. (@as(usize, cols) * rows * cell_size) + buf_extra];
            cleared = cleared_framebuf[0..buf.len];
            aspect = @as(f32, @floatFromInt(cols)) / @as(f32, @floatFromInt(rows));
            for (0..@as(usize, rows) * cols) |i| {
                put_clear_cell(cleared, i);
            }
        }
        const fr_until_now = last.untilNow(init.io, clock);
        const dt_ms = last.untilNow(init.io, clock).toMilliseconds();
        const dt = @as(f32, @floatFromInt(dt_ms)) / 1000;
        const now = clock.now(init.io);
        last = now;

        @memcpy(buf, cleared);

        inline for (mesh, 0..) |v, i| {
            out[i] = pitch(yaw(v + translate, -yaw_a), -pitch_a);
        }

        const stdin_len = stdin.readStreaming(
            init.io,
            &[_][]u8{&stdinbuf},
        ) catch |e| switch (e) {
            error.WouldBlock => 0,
            error.EndOfStream => 0,
            else => 0, // TODO: handle errors?
        };
        if (stdin_len > 0) {
            var r = Io.Reader.fixed(stdinbuf[0..stdin_len]);
            // parse all key codes in stdin to see which keys are
            // pressed down and translate/transform all at once
            while (r.seek < r.end) {
                if (key.parse(&r)) |k| {
                    const key_is_down = k.event != .release;
                    inline for (@typeInfo(@TypeOf(curr_keys_down)).@"struct".field_names) |n| {
                        if (k.key == n[0]) @field(curr_keys_down, n) = key_is_down;
                        if (k.key == 'c' and k.mod.ctrl) should_quit.store(true, .release);
                    }
                }
            }
        }

        const d = move_per_sec * dt;
        inline for (0.., @typeInfo(@TypeOf(curr_keys_down)).@"struct".field_names) |i, n| {
            if (@field(curr_keys_down, n)) {
                switch (i) {
                    0 => translate += yaw(Vec3{ 0, 0, d }, yaw_a),
                    1 => translate += yaw(Vec3{ d, 0, 0 }, yaw_a),
                    2 => translate += yaw(Vec3{ 0, 0, -d }, yaw_a),
                    3 => translate += yaw(Vec3{ -d, 0, 0 }, yaw_a),
                    4 => yaw_a += d * 0.3,
                    5 => pitch_a -= d * 0.3,
                    6 => pitch_a += d * 0.3,
                    7 => yaw_a -= d * 0.3,
                    8 => translate += Vec3{ 0, -d, 0 },
                    9 => translate += Vec3{ 0, d, 0 },
                    else => unreachable,
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

        put_cell_fg(buf, 0, .{ 165, 119, 202 }, 'F');
        put_cell_fg(buf, 1, .{ 165, 119, 202 }, 'P');
        put_cell_fg(buf, 2, .{ 165, 119, 202 }, 'S');

        // 500ms in ns
        if (fps_ns >= 500_000_000) {
            last_fps = (frames * 1_000_000_000) / fps_ns;
            frames = 0;
            fps_ns = 0;
        }
        const num = try std.mem.print(buf[4..], "{d:0>6}", .{last_fps % 1000000});
        for (num, 0..) |n, i| {
            // 4 = FPS len + 1 space
            put_cell_fg(buf, 4 + i, .{ 210, 170, 85 }, n);
        }

        try stdout.writeStreamingAll(init.io, framebuf[0 .. buf.len + buf_extra]);
        try init.io.sleep(
            Io.Duration.fromMilliseconds(ms_to_sleep / 2),
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
    return .{ ndc[0] * w, ndc[1] * h };
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

    return .{ x1 / w, y1 / w };
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

/// Draw line calculating slope and diffs.
fn draw_line(v0: Vec2, v1: Vec2, buf: []u8, rgb: RGB) void {
    // -1 or 1
    const dx = v1[0] - v0[0];
    const dy = v1[1] - v0[1];
    const step: f32 = @max(@abs(dx), @abs(dy));
    if (step == 0) return;

    const stepX = dx / step;
    const stepY = dy / step;

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = half_rows - @as(isize, @round(
            v0[1] + ii * stepY,
        ));
        const col = half_cols + @as(isize, @round(
            v0[0] + ii * stepX,
        ));
        if (row >= 0 and row < rows and col >= 0 and col < cols) {
            put_cell_fg(buf, @intCast(row * cols + col), line_char, rgb);
        }
    }
}

fn draw_line3(v0: Vec2, v1: Vec2, v2: Vec2, buf: []u8, rgb: RGB) void {
    draw_line(v0, v1, buf, rgb);
    draw_line(v1, v2, buf, rgb);
    draw_line(v2, v0, buf, rgb);
}

// top left convention to solve overdraw
fn is_top_left(start: Vec2, end: Vec2) bool {
    const e = end - start;
    return e[1] > 0 or (e[1] == 0 and e[0] < 0);
}

/// Return a positive number if `p` is on the left side of `a` and `b`
fn edge_cross(a: Vec2, b: Vec2, p: Vec2) f32 {
    const ab = b - a;
    const ap = p - a;
    return ab[0] * ap[1] - ab[1] * ap[0];
}

/// Barycentric coordinates
fn bary(v0: Vec2, v1: Vec2, v2: Vec2, p: Vec2) Vec3 {
    const area: Vec3 = @splat(edge_cross(v0, v1, v2) / 1);
    const alpha = edge_cross(v1, v2, p) / 1;
    const beta = edge_cross(v2, v0, p) / 1;
    const gamma = edge_cross(v0, v1, p) / 1;
    return Vec3{ alpha, beta, gamma } / area;
}

fn rasterize(v0: Vec2, v1: Vec2, v2: Vec2, buf: []u8) void {
    const area = edge_cross(v0, v1, v2);
    // trick to divide once per triangle instead of per pixel
    // remove this if color interpolation is no longer used
    const inv_area: Vec3 = @splat(1.0 / area);
    const x_min: i32 = @floor(@min(v0[0], v1[0], v2[0]));
    const x_max: i32 = @ceil(@max(v0[0], v1[0], v2[0]));
    const y_min: i32 = @floor(@min(v0[1], v1[1], v2[1]));
    const y_max: i32 = @ceil(@max(v0[1], v1[1], v2[1]));
    const bias: Vec3 = .{
        if (is_top_left(v1, v2)) 0 else -0.0001,
        if (is_top_left(v2, v0)) 0 else -0.0001,
        if (is_top_left(v0, v1)) 0 else -0.0001,
    };
    // don't loop over pixels outside the screen
    const x_start: i32 = @max(x_min, -half_cols);
    const x_end: i32 = @min(x_max, cols - half_cols);
    const y_start: i32 = @max(y_min, half_rows - (rows - 1));
    const y_end: i32 = @min(y_max, half_rows + 1);
    var topleft = Vec2{ @floatFromInt(x_start), @floatFromInt(y_start) };
    topleft += @splat(0.5);

    // barycentric weights (determinants)
    var wleft = (Vec3{
        edge_cross(v1, v2, topleft),
        edge_cross(v2, v0, topleft),
        edge_cross(v0, v1, topleft),
    } + bias) * inv_area;

    const dw_dx = Vec3{ v1[1] - v2[1], v2[1] - v0[1], v0[1] - v1[1] } * inv_area;
    const dw_dy = Vec3{ v2[0] - v1[0], v0[0] - v2[0], v1[0] - v0[0] } * inv_area;
    // calculate difference in color change for x and y
    const dc_dx = Vec3{ RED[0] * dw_dx[0], GREEN[1] * dw_dx[1], BLUE[2] * dw_dx[2] };
    const dc_dy = Vec3{ RED[0] * dw_dy[0], GREEN[1] * dw_dy[1], BLUE[2] * dw_dy[2] };

    // incremental calculation of color and w
    var color_left = RED * wleft + GREEN * wleft + BLUE * wleft;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row_start = @as(usize, @intCast(half_rows - y)) * cols;
        var w = wleft;
        var x = x_start;
        var color = color_left;

        while (x < x_end) : (x += 1) {
            if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                const col: usize = @intCast(half_cols + x);
                put_cell_bg(buf, row_start + col, @round(color));
            }
            w += dw_dx;
            color += dc_dx;
        }
        wleft += dw_dy;
        color_left += dc_dy;
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

const RED: RGB = .{ 255, 0, 0 };
const GREEN: RGB = .{ 0, 255, 0 };
const BLUE: RGB = .{ 0, 0, 255 };

const ColorType = enum(u8) { fg = '3', bg = '4' };

// \x1b[38;2;25;10;200mtext_go_here
fn put_cell(buf: []u8, i: usize, rgb: RGB, char: u8, code: ColorType) void {
    const offset: usize = i * cell_size;
    if (offset + cell_size > buf.len) return;
    buf[offset..][0..7].* = .{ 0x1b, '[', @backingInt(code), '8', ';', '2', ';' };
    buf[offset..][10..11].* = .{';'};
    buf[offset..][14..15].* = .{';'};
    buf[offset..][18..19].* = .{'m'};
    buf[offset..][19..20].* = .{char};
    _ = std.mem.print(buf[offset..][7..10], "{d:0>3}", .{rgb[0]}) catch unreachable;
    _ = std.mem.print(buf[offset..][11..14], "{d:0>3}", .{rgb[1]}) catch unreachable;
    _ = std.mem.print(buf[offset..][15..18], "{d:0>3}", .{rgb[2]}) catch unreachable;
}

fn put_clear_cell(buf: []u8, i: usize) void {
    const offset: usize = i * cell_size;
    buf[offset..][0..20].* = .{
        0x1b, '[', '0', '0', '0', '0', '0', '0', '0', '0',
        ';',  '0', '0', '0', ';', '0', '0', '0', 'm', ' ',
    };
}

fn put_cell_fg(buf: []u8, i: usize, rgb: RGB, char: u8) void {
    put_cell(buf, i, rgb, char, .fg);
}

fn put_cell_bg(buf: []u8, i: usize, rgb: RGB) void {
    put_cell(buf, i, rgb, ' ', .bg);
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
// background = 19 bytes + text bytes
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
//
// cool pattern \/
// @round(
//     math.lerp(RED, GREEN, alpha) +
//     math.lerp(GREEN, BLUE, beta) +
//     math.lerp(BLUE, RED, gamma)
// );
