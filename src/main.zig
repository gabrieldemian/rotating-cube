pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const RGB = Vec3;

const move_per_sec = 7.0;
const fps: u32 = 60;
const ms_to_sleep: i64 = @trunc((1000 / @as(f32, fps)));
const buf_extra = 3;

pub var should_quit = std.atomic.Value(bool).init(false);
pub var should_resize = std.atomic.Value(bool).init(false);
var framebuf: [300 * 150 * term.cell_size + buf_extra]u8 = undefined;
var cleared_framebuf: [framebuf.len - buf_extra]u8 = undefined;
var zbuf_raw: [300 * 150]f32 = undefined;
var stdinbuf: [100]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const stdout = Io.File.stdout();
    const stdin = Io.File.stdin();
    term.resize(stdout);
    try term.init(stdout, init.io);
    defer term.deinit(stdout, init.io) catch {};
    try term.raw_mode();
    defer term.leave_raw_mode() catch {};

    framebuf[0..3].* = [3]u8{ 0x1b, '[', 'H' };
    var buf =
        framebuf[buf_extra..(@as(usize, term.cols) * term.rows * term.cell_size + buf_extra)];

    const terminal_scale = Vec3{ 1, 0.5, 1 };
    var aspect = @as(f32, @floatFromInt(term.cols)) / @as(f32, @floatFromInt(term.rows));

    const clock = std.Io.Clock.boot;
    var last = clock.now(init.io);
    var frames: u64 = 0;
    var fps_ns: u32 = 0;

    const cube = try obj.open("mountains.obj", init.arena, init.io);

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
    for (0..@as(usize, term.rows) * term.cols) |i| {
        term.put_clear_cell(cleared, i);
    }

    var translate: Vec3 = .{ 0, 0, -3.5 };
    var yaw_a: f32 = 0;
    var pitch_a: f32 = 0;
    var last_fps: u64 = 0;
    var out = try init.arena.allocator().alloc(Vec3, cube.mesh.len);
    var zbuf = zbuf_raw[0 .. @as(usize, term.cols) * term.rows];

    while (!should_quit.load(.acquire)) {
        if (should_resize.swap(false, .seq_cst)) {
            term.resize(stdout);
            buf = framebuf[buf_extra .. (@as(usize, term.cols) * term.rows * term.cell_size) + buf_extra];
            cleared = cleared_framebuf[0..buf.len];
            aspect = @as(f32, @floatFromInt(term.cols)) / @as(f32, @floatFromInt(term.rows));
            zbuf = zbuf_raw[0 .. @as(usize, term.cols) * term.rows];
            for (0..@as(usize, term.rows) * term.cols) |i| {
                term.put_clear_cell(cleared, i);
            }
        }
        const fr_until_now = last.untilNow(init.io, clock);
        const dt_ns = last.untilNow(init.io, clock).toNanoseconds();
        // nanos to millis
        const dt = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000;
        const now = clock.now(init.io);
        last = now;

        @memcpy(buf, cleared);
        @memset(zbuf, 1);

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

        // --------------
        //     inputs
        // --------------

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

        // --------------
        //    pipeline
        // --------------

        // cube_a += 0.008;
        for (cube.mesh, 0..) |v, i| {
            // still
            out[i] = pitch(yaw(v + translate, -yaw_a), -pitch_a);
            // rotating
            // out[i] = pitch(yaw(v, cube_a), cube_a) + translate;
            // out[i] = pitch(yaw(out[i], -yaw_a), -pitch_a);
        }

        {
            var i: usize = 0;
            while (i + 2 < cube.tris.len) : (i += 3) {
                const t0 = out[cube.tris[i + 0] - 1];
                const t1 = out[cube.tris[i + 1] - 1];
                const t2 = out[cube.tris[i + 2] - 1];
                if (utils.is_visible(t0, t1, t2)) {
                    // draw_line3(
                    //     screen_space(project(t0, aspect) * terminal_scale),
                    //     screen_space(project(t1, aspect) * terminal_scale),
                    //     screen_space(project(t2, aspect) * terminal_scale),
                    //     buf,
                    //     RED,
                    // );

                    const p0 = project(t0, aspect) * terminal_scale;
                    const p1 = project(t1, aspect) * terminal_scale;
                    const p2 = project(t2, aspect) * terminal_scale;

                    _ = rasterize(
                        screen_space(p0),
                        screen_space(p1),
                        screen_space(p2),
                        buf,
                        zbuf,
                        lumi(t0, t1, t2),
                    );
                }
            }
        }

        // ---------------------
        //     fps and flush
        // ---------------------

        frames += 1;
        fps_ns += @intCast(fr_until_now.toNanoseconds());

        // 500ms in ns
        if (fps_ns >= 500_000_000) {
            last_fps = (frames * 1_000_000_000) / fps_ns;
            frames = 0;
            fps_ns = 0;
        }
        const v = last_fps % 10000;
        inline for (.{ 1000, 100, 10, 1 }, 0..) |div, i| {
            const num: u8 = @intCast((v / div) % 10);
            term.put_cell_fg(buf, i, RED, '0' + num);
        }

        try stdout.writeStreamingAll(init.io, framebuf[0 .. buf.len + buf_extra]);
        // try init.io.sleep(
        //     Io.Duration.fromMilliseconds(ms_to_sleep / 2),
        //     Io.Clock.boot,
        // );
    }
}

/// Draw line calculating slope and diffs.
fn draw_line(v0: anytype, v1: anytype, buf: []u8, rgb: RGB) void {
    // -1 or 1
    const dx = v1[0] - v0[0];
    const dy = v1[1] - v0[1];
    const step: f32 = @max(@abs(dx), @abs(dy));
    if (step == 0) return;

    const stepX = dx / step;
    const stepY = dy / step;

    for (0..(@as(usize, @round(step))) + 1) |i| {
        const ii = @as(f32, @floatFromInt(i));
        const row = term.half_rows - @as(isize, @round(
            v0[1] + ii * stepY,
        ));
        const col = term.half_cols + @as(isize, @round(
            v0[0] + ii * stepX,
        ));
        if (row >= 0 and row < term.rows and col >= 0 and col < term.cols) {
            term.put_cell_fg(buf, @intCast(row * term.cols + col), rgb, '.');
        }
    }
}

fn draw_line3(v0: anytype, v1: anytype, v2: anytype, buf: []u8, rgb: RGB) void {
    draw_line(v0, v1, buf, rgb);
    draw_line(v1, v2, buf, rgb);
    draw_line(v2, v0, buf, rgb);
}

// top left convention to solve overdraw
fn is_top_left(start: Vec2, end: Vec2) bool {
    const e = end - start;
    return e[1] > 0 or (e[1] == 0 and e[0] < 0);
}

fn rasterize(vv0: Vec3, vv1: Vec3, vv2: Vec3, buf: []u8, zbuf: []f32, l: Vec3) void {
    const v0 = Vec2{ vv0[0], vv0[1] };
    const v1 = Vec2{ vv1[0], vv1[1] };
    const v2 = Vec2{ vv2[0], vv2[1] };
    const x_min: i32 = @floor(@min(v0[0], v1[0], v2[0]));
    const x_max: i32 = @ceil(@max(v0[0], v1[0], v2[0]));
    const y_min: i32 = @floor(@min(v0[1], v1[1], v2[1]));
    const y_max: i32 = @ceil(@max(v0[1], v1[1], v2[1]));
    const bias: Vec3 = .{
        if (is_top_left(v1, v2)) 0 else -0.0000001,
        if (is_top_left(v2, v0)) 0 else -0.0000001,
        if (is_top_left(v0, v1)) 0 else -0.0000001,
    };
    // don't loop over pixels outside the screen
    const x_start: i32 = @max(x_min, -term.half_cols);
    const x_end: i32 = @min(x_max, term.cols - term.half_cols);
    const y_start: i32 = @max(y_min, term.half_rows - (term.rows - 1));
    const y_end: i32 = @min(y_max, term.half_rows + 1);
    var topleft = Vec2{ @floatFromInt(x_start), @floatFromInt(y_start) };
    topleft += @splat(0.5);

    const inv_area = 1.0 / utils.edge_cross(v0, v1, v2);
    var wleft = (Vec3{
        utils.edge_cross(v1, v2, topleft),
        utils.edge_cross(v2, v0, topleft),
        utils.edge_cross(v0, v1, topleft),
    } + bias); // divide by area for true bary and remove inv_area

    const dw_dx = Vec3{ v1[1] - v2[1], v2[1] - v0[1], v0[1] - v1[1] };
    const dw_dy = Vec3{ v2[0] - v1[0], v0[0] - v2[0], v1[0] - v0[0] };

    const dz_dx = (dw_dx[0] * vv0[2] + dw_dx[1] * vv1[2] + dw_dx[2] * vv2[2]) * inv_area;
    const dz_dy = (dw_dy[0] * vv0[2] + dw_dy[1] * vv1[2] + dw_dy[2] * vv2[2]) * inv_area;

    var z_left = (wleft[0] * vv0[2] + wleft[1] * vv1[2] + wleft[2] * vv2[2]) * inv_area;
    var y = y_start;

    while (y < y_end) : (y += 1) {
        const row_start = @as(usize, @intCast(term.half_rows - y)) * term.cols;
        var w = wleft;
        var x = x_start;
        var z = z_left;

        while (x < x_end) : (x += 1) {
            if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                const col: usize = @intCast(term.half_cols + x);
                if (z < zbuf[row_start + col]) {
                    zbuf[row_start + col] = z;
                    term.put_cell_bg(buf, row_start + col, @round(GREY * l));
                }
            }
            w += dw_dx;
            z += dz_dx;
        }
        z_left += dz_dy;
        wleft += dw_dy;
    }
}

fn rasterize2(v0: Vec2, v1: Vec2, v2: Vec2, buf: []u8, l: Vec3) void {
    const color = @round(GREY * l);
    const x_min: i32 = @floor(@min(v0[0], v1[0], v2[0]));
    const x_max: i32 = @ceil(@max(v0[0], v1[0], v2[0]));
    const y_min: i32 = @floor(@min(v0[1], v1[1], v2[1]));
    const y_max: i32 = @ceil(@max(v0[1], v1[1], v2[1]));
    const bias: Vec3 = .{
        if (is_top_left(v1, v2)) 0 else -0.000001,
        if (is_top_left(v2, v0)) 0 else -0.000001,
        if (is_top_left(v0, v1)) 0 else -0.000001,
    };
    // don't loop over pixels outside the screen
    const x_start: i32 = @max(x_min, -term.half_cols);
    const x_end: i32 = @min(x_max, term.cols - term.half_cols);
    const y_start: i32 = @max(y_min, term.half_rows - (term.rows - 1));
    const y_end: i32 = @min(y_max, term.half_rows + 1);
    var topleft = Vec2{ @floatFromInt(x_start), @floatFromInt(y_start) };
    topleft += @splat(0.5);

    // barycentric weights (determinants)
    var wleft = (Vec3{
        utils.edge_cross(v1, v2, topleft),
        utils.edge_cross(v2, v0, topleft),
        utils.edge_cross(v0, v1, topleft),
    } + bias);

    const dw_dx = Vec3{ v1[1] - v2[1], v2[1] - v0[1], v0[1] - v1[1] };
    const dw_dy = Vec3{ v2[0] - v1[0], v0[0] - v2[0], v1[0] - v0[0] };

    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row_start = @as(usize, @intCast(term.half_rows - y)) * term.cols;
        var w = wleft;
        var x = x_start;

        while (x < x_end) : (x += 1) {
            if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                const col: usize = @intCast(term.half_cols + x);
                term.put_cell_bg(buf, row_start + col, color);
            }
            w += dw_dx;
        }
        wleft += dw_dy;
    }
}

const RED: RGB = .{ 255, 0, 0 };
const GREEN: RGB = .{ 0, 255, 0 };
const BLUE: RGB = .{ 0, 0, 255 };
const GREY: RGB = .{ 190, 190, 190 };

const std = @import("std");
const Io = std.Io;
const math = std.math;
const print = std.debug.print;
const posix = std.posix;
const expect = std.testing.expect;

const key = @import("key.zig");
const obj = @import("obj.zig");
const term = @import("term.zig");
const utils = @import("utils.zig");
const normal = utils.normal;
const yaw = utils.yaw;
const pitch = utils.pitch;
const magnitude = utils.magnitude;
const dot = utils.dot;
const project = utils.project;
const screen_space = utils.screen_space;
const lumi = utils.lumi;
