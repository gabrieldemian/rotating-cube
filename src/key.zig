// Parser for kitty keyboard protocol
// https://sw.kovidgoyal.net/kitty/keyboard-protocol

const std = @import("std");
const Reader = std.Io.Reader;

pub const Event = enum(u8) { press = '1', repeat = '2', release = '3' };
pub const Key = struct {
    event: Event,
    mod: Modifier,
    key: u8,
};
pub const Modifier = packed struct(u8) {
    shift: bool,
    alt: bool,
    ctrl: bool,
    super: bool,
    hyper: bool,
    meta: bool,
    caps_lock: bool,
    num_lock: bool,
};

pub fn parse(r: *Reader) ?Key {
    if (r.buffered().len < 4) return null;
    // 0 init
    // 1 past x1b
    // 2 past x5b
    // 3 parsing key
    // 4 past key
    // 5 past modifier
    // 6 end 'u'
    var state: u8 = 0;
    var modifier: Modifier = @fromBackingInt(0);
    var event: ?Event = null;
    var value: u32 = 0;
    const buf = r.buffered();
    // std.debug.print("s: {s} \n", .{buf});
    for (buf) |byte| {
        r.seek += 1;
        switch (byte) {
            0x1b => if (state > 0) return null else {
                state = 1;
            },
            0x5b => if (state != 1) return null else {
                state = 2;
            },
            'u' => {
                if (state < 3) return null;
                state = 6;
                break;
            },
            '0'...'9' => {
                if (state < 2) return null;
                if (state < 4) {
                    value *= 10;
                    value += byte - '0';
                    state = 3;
                }
                if (state == 5) {
                    event = @fromBackingInt(@intCast(byte));
                }
                if (state == 4) {
                    modifier = @fromBackingInt(byte - '0');
                    state = 5;
                }
            },
            ';' => {
                if (state == 3) { // parsing key
                    state = 4; // past key
                }
            },
            ':' => {
                if (state == 4) return null;
                state = 5;
            },
            else => return null,
        }
    }
    if (state != 6) return null;
    // skip empty modifiers ctrl shift etc
    // since we get their values soon after,
    // its pointless to get the modifier alone.
    if (value >= 57344 and value <= 63743) {
        return null;
    }
    return Key{
        .event = event orelse Event.press,
        .mod = modifier,
        .key = @intCast(value),
    };
}

const print = std.debug.print;
const expect = std.testing.expect;

test "parse_w" {
    const buf = [_]u8{ 0x1b, '[', '1', '1', '9', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.event == .press);
    try expect(res.key == 'w');
    try expect(r.seek == buf.len);
}

test "parse_w_2" {
    const buf = [_]u8{
        0x1b, '[', '1', '1', '9', 'u',
        0x1b, '[', '1', '1', '9', 'u',
    };
    var r = Reader.fixed(&buf);
    for (1..4) |i| {
        const res = parse(&r).?;
        try expect(res.event == .press);
        try expect(res.key == 'w');
        try expect(r.seek == i * 6);
    }
}

test "parse_w_3" {
    const buf = [_]u8{
        0x1b, '[', '1', '1', '9', 'u',
        0x1b, '[', '1', '1', '9', ';',
        '1',  ':', '3', 'u',
    };
    var r = Reader.fixed(&buf);
    for (0..2) |i| {
        const res = parse(&r).?;
        try expect(res.key == 'w');
        if (i == 0) {
            try expect(res.event == .press);
            try expect(r.seek == 6);
        } else {
            try expect(res.event == .release);
            try expect(r.seek == 16);
        }
    }
}

test "parse_w_mod" {
    const buf = [_]u8{ 0x1b, '[', '1', '1', '9', ';', '1', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.event == .press);
    try expect(res.key == 'w');
    try expect(r.end == buf.len);
}

test "parse_w_mod_event" {
    const buf = [_]u8{ 0x1b, '[', '1', '1', '9', ';', '1', ':', '1', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.event == .press);
    try expect(res.key == 'w');
    try expect(r.end == buf.len);
}

test "parse_w_mod_event_repeat" {
    const buf = [_]u8{ 0x1b, '[', '1', '1', '9', ';', '1', ':', '2', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.event == .repeat);
    try expect(res.key == 'w');
    try expect(r.end == buf.len);
}

test "parse_w_mod_event_release" {
    const buf = [_]u8{ 0x1b, '[', '1', '1', '9', ';', '1', ':', '3', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.event == .release);
    try expect(res.key == 'w');
    try expect(r.end == buf.len);
}

// test "parse_mods" {
//     const buf = [_]u8{ 0x1b, '[', '5', '7', '4', '4', '2', ';', '1', ':', '3', 'u' };
//     const r = parse(&buf).?;
//     try expect(r.key == 57442);
//     try expect(r.event == .release);
//     try expect(r.mod.shift);
// }

test "parse_ctrl_c_press" {
    const buf = [_]u8{ 0x1b, '[', '9', '9', ';', '5', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.key == 'c');
    try expect(res.event == .press);
    try expect(res.mod.ctrl);
    try expect(r.end == buf.len);
}

test "parse_ctrl_c_release" {
    const buf = [_]u8{ 0x1b, '[', '9', '9', ';', '5', ':', '3', 'u' };
    var r = Reader.fixed(&buf);
    const res = parse(&r).?;
    try expect(res.key == 'c');
    try expect(res.event == .release);
    try expect(res.mod.ctrl);
    try expect(r.end == buf.len);
}

// [119u[119;1:3u

// DEL
// [3~ x: 1b5b337e
// [3;1:3~ x: 1b5b333b313a337e

// enter
// [13;1:3u x: 1b5b31333b313a3375
// [13u x: 1b5b313375

// space
// [13;1:3u x: 1b5b31333b313a3375
// [32u x: 1b5b333275

// shift
// [57442;1:3u x: 1b5b35373434323b313a3375
// [57441;2u x: 1b5b35373434313b3275

// ctrl
// [57442;5u x: 1b5b35373434323b3575
// [57442;1:3u x: 1b5b35373434323b313a3375

// ctrl C
// [99;5u x: 1b5b39393b3575
// [99;5:3u x: 1b5b39393b353a3375

// esc
// [27u x: 1b5b323775
// [27;1:3u x: 1b5b32373b313a3375

// f1
// [1;1:1P x: 1b5b313b313a3150
// [1;1:3P x: 1b5b313b313a3350

// shift+a -> CSI 97 ; 2 ; 65 u   # The text 'A' is reported as 65
// alt+a   -> CSI  0 ;   ; 229 u  # The text 'å' is reported as 229
