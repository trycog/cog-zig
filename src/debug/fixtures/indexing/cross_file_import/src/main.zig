const model = @import("model.zig");

pub fn main() void {
    const m = model.makeModel();
    const z = m.amount;
    _ = z;
}
