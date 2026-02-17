fn Box(comptime T: type) type {
    return struct {
        value: T,
    };
}

pub fn main() void {
    const IntBox = Box(i32);
    const boxed = IntBox{ .value = 9 };
    const x = boxed.value;
    _ = x;
}
