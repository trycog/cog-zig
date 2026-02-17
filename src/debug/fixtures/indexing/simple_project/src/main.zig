const std = @import("std");

const Person = struct {
    name: []const u8,
};

fn greet(person: Person) []const u8 {
    return person.name;
}

pub fn main() !void {
    const p = Person{ .name = "cog" };
    _ = greet(p);
    try std.io.getStdOut().writer().print("ok\n", .{});
}
