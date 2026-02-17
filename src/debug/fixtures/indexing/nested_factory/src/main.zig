const Inner = struct {
    value: i32,
};

const Outer = struct {
    inner: Inner,
};

fn buildOuter() Outer {
    return .{ .inner = .{ .value = 7 } };
}

pub fn main() void {
    const y = buildOuter().inner.value;
    _ = y;
}
