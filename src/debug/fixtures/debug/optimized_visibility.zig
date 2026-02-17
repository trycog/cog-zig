const std = @import("std");

fn compute(input: i32) i32 {
    var acc: i32 = input;
    acc += 10;
    return acc * 2;
}

pub fn main() !void {
    const value = compute(6);
    try std.io.getStdOut().writer().print("value={d}\n", .{value});
}
