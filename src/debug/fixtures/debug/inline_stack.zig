const std = @import("std");

inline fn triple(x: i32) i32 {
    return x * 3;
}

pub fn main() !void {
    const start: i32 = 5;
    const result = triple(start);
    try std.io.getStdOut().writer().print("{d}\n", .{result});
}
