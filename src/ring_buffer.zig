const std = @import("std");

/// A append only ring buffer designed for storing temporary data. When full, new data overwrites
/// old data. The tradeoffs made are *not* suitable for multithreaded producer/consumer style usage.
pub fn RingBuffer(T: type, log2_capacity: u6) type {
    return struct {
        // Calculate the power of two capacity, and then pick the index type that's an exact fit so
        // that wrapping is easy.
        const capacity: usize = std.math.pow(usize, 2, log2_capacity);
        const Index = std.meta.Int(.unsigned, log2_capacity);

        items: [capacity]T = undefined,
        len: usize = 0,
        end: Index = 0,

        pub fn addOne(self: *@This()) *T {
            const result = &self.items[self.end];
            self.end +%= 1;
            self.len = @min(self.len + 1, capacity);
            return result;
        }

        pub fn append(self: *@This(), item: T) void {
            self.addOne().* = item;
        }

        // Appends an undefined contiguous slice as large as possible up to the given max to the
        // ring buffer and returns it.
        pub fn addManyAsSlice(self: *@This(), max_len: usize) []T {
            const start = self.end;
            const len = @min(capacity - start, max_len);
            self.end +%= @truncate(len);
            self.len = @min(self.len + len, capacity);
            return self.items[start..(start + len)];
        }

        pub fn index(self: *const @This(), i: usize) usize {
            // Get the starting position
            const start = self.end -% @as(Index, @truncate(self.len));

            // Offset and maybe wrap the given index. This cast is fine because if it overflows,
            // we're out of bounds anyway.
            return start +% @as(Index, @intCast(i));
        }

        pub fn pop(self: *@This()) void {
            self.len -= 1;
        }
    };
}

fn expectRingBufferEqual(T: type, slice: []const T, ring: anytype) !void {
    try std.testing.expectEqual(slice.len, ring.len);
    for (slice, 0..) |expected, i| {
        const index = ring.index(i);
        try std.testing.expectEqual(expected, ring.items[index]);
    }
}

test "RingBuffer.append" {
    var array: std.ArrayList(u8) = .empty;
    defer array.deinit(std.testing.allocator);
    var buf = RingBuffer(u8, 2){};

    try expectRingBufferEqual(u8, array.items[0..0], &buf);

    buf.append(5);
    try array.append(std.testing.allocator, 5);
    try expectRingBufferEqual(u8, array.items[(array.items.len - 1)..array.items.len], &buf);
    buf.append(10);
    try array.append(std.testing.allocator, 10);
    try expectRingBufferEqual(u8, array.items[(array.items.len - 2)..array.items.len], &buf);
    buf.append(15);
    try array.append(std.testing.allocator, 15);
    try expectRingBufferEqual(u8, array.items[(array.items.len - 3)..array.items.len], &buf);
    buf.append(20);
    try array.append(std.testing.allocator, 20);
    try expectRingBufferEqual(u8, array.items[(array.items.len - 4)..array.items.len], &buf);

    for (0..1000) |i| {
        // Add some random value
        const item: u8 = @truncate(i * 3);
        buf.append(item);
        try array.append(std.testing.allocator, item);

        // Make sure the ring buffer still matches the end of the array list
        try expectRingBufferEqual(u8, array.items[(array.items.len - 4)..array.items.len], &buf);
    }
}

test "RingBuffer.pop" {
    var buf = RingBuffer(u8, 2){};

    // Fill the buffer
    buf.append(5);
    buf.append(10);
    buf.append(15);
    buf.append(20);

    // Pop all one at a time
    try expectRingBufferEqual(u8, &.{ 5, 10, 15, 20 }, &buf);
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 10, 15, 20 }, &buf);
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 15, 20 }, &buf);
    buf.pop();
    try expectRingBufferEqual(u8, &.{20}, &buf);
    buf.pop();
    try expectRingBufferEqual(u8, &.{}, &buf);

    // Interleave filling and popping
    buf.append(1);
    buf.append(2);
    buf.append(3);
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 2, 3 }, &buf);
    buf.append(4);
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 3, 4 }, &buf);
    buf.append(5);
    buf.append(6);
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 4, 5, 6 }, &buf);
    buf.append(7);
    buf.pop();
    buf.pop();
    try expectRingBufferEqual(u8, &.{ 6, 7 }, &buf);
}

test "RingBuffer.addManyAsSlice" {
    // Test length of returned slice
    for (0..9) |max_len| {
        for (0..9) |offset| {
            var buf = RingBuffer(u8, 2){};
            for (0..offset) |_| _ = buf.addOne();
            const expected_len = @min(max_len, 4 - (offset % 4));
            const actual_len = buf.addManyAsSlice(max_len).len;
            try std.testing.expectEqual(expected_len, actual_len);
        }
    }

    // Test some simple examples
    var buf: RingBuffer(u8, 2) = .{};

    @memcpy(buf.addManyAsSlice(4), @as([]const u8, &.{ 2, 4, 6, 8 }));
    try expectRingBufferEqual(u8, &.{ 2, 4, 6, 8 }, &buf);

    @memcpy(buf.addManyAsSlice(2), @as([]const u8, &.{ 10, 20 }));
    try expectRingBufferEqual(u8, &.{ 6, 8, 10, 20 }, &buf);

    @memcpy(buf.addManyAsSlice(4), @as([]const u8, &.{ 13, 14 }));
    try expectRingBufferEqual(u8, &.{ 10, 20, 13, 14 }, &buf);

    @memcpy(buf.addManyAsSlice(2), @as([]const u8, &.{ 15, 16 }));
    try expectRingBufferEqual(u8, &.{ 13, 14, 15, 16 }, &buf);

    @memcpy(buf.addManyAsSlice(2), @as([]const u8, &.{ 17, 18 }));
    try expectRingBufferEqual(u8, &.{ 15, 16, 17, 18 }, &buf);

    @memcpy(buf.addManyAsSlice(4), @as([]const u8, &.{ 19, 20, 21, 22 }));
    try expectRingBufferEqual(u8, &.{ 19, 20, 21, 22 }, &buf);
}
