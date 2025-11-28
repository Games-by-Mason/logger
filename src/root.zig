const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");

pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const Options = struct {
    show_info_prefix: bool = true,
    show_scope: bool = true,
    history: struct {
        pub const none: @This() = .{
            .entries_log2_capacity = 0,
            .text_log2_capacity = 0,
        };
        pub const large: @This() = .{
            .entries_log2_capacity = 16,
            .text_log2_capacity = 16,
        };
        pub const debug: @This() = if (builtin.mode == .Debug) .large else .none;

        entries_log2_capacity: u6,
        text_log2_capacity: u6,
    },
};

pub const Entry = struct {
    level: std.log.Level,
    scope: []const u8,
    message: []const u8,
    time_ms: i64,
};

pub fn Logger(options: Options) type {
    return struct {
        /// The min level to log to standard error.
        pub var stderr_level: std.log.Level = .debug;
        /// The min level to log to the history ring buffer.
        pub var ring_level: std.log.Level = .debug;
        /// The writer to write to the writer.
        pub var writer_level: std.log.Level = .debug;
        /// If present, logs are written to this writer. Typically used to write logs to disk,
        /// assign this field at runtime as soon as you're able to create the writer.
        pub var writer: ?*std.Io.Writer = null;

        var text: RingBuffer(u8, options.history.text_log2_capacity) = .{};
        pub var entries: RingBuffer(Entry, options.history.entries_log2_capacity) = .{};
        pub var level_count = std.EnumArray(std.log.Level, u64).initFill(0);

        pub fn getEntry(index: usize) ?*const Entry {
            if (index >= entries.len) return null;
            const i = entries.index(index);
            return &entries.items[i];
        }

        pub fn logFn(
            comptime message_level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            // Check the runtime log levels
            const log_stderr = @intFromEnum(message_level) <= @intFromEnum(stderr_level);
            const log_history = @intFromEnum(message_level) <= @intFromEnum(ring_level);
            const log_writer = writer != null and @intFromEnum(message_level) <= @intFromEnum(writer_level);
            if (!log_stderr and !log_history and !log_writer) return;

            const time_ms = std.time.milliTimestamp();

            const bold = "\x1b[1m";
            const gray = "\x1b[90m";
            const color = switch (message_level) {
                .err => "\x1b[31m",
                .info => "\x1b[32m",
                .debug => "\x1b[34m",
                .warn => "\x1b[33m",
            };
            const reset = "\x1b[0m";
            const level_txt = comptime message_level.asText();
            const scope_txt = "(" ++ @tagName(scope) ++ ")";

            // We use the stderr lock for locking everything for now. This can be made more fine
            // grained in the future by creating separate locks per output if needed.
            var stderr_buf: [128]u8 = undefined;
            const stderr = std.debug.lockStderrWriter(&stderr_buf);
            defer std.debug.unlockStderrWriter();
            nosuspend {
                level_count.getPtr(message_level).* +|= 1;

                if (log_stderr) {
                    var wrote_prefix = false;
                    if (message_level != .info or options.show_info_prefix) {
                        stderr.writeAll(bold ++ color ++ level_txt ++ reset) catch return;
                        wrote_prefix = true;
                    }
                    if (options.show_scope) {
                        stderr.writeAll(gray ++ bold ++ scope_txt ++ reset) catch return;
                        wrote_prefix = true;
                    }
                    if (message_level == .err) stderr.writeAll(bold) catch return;
                    if (wrote_prefix) {
                        stderr.writeAll(": ") catch return;
                    }
                    stderr.print(format ++ "\n", args) catch return;
                    stderr.writeAll(reset) catch return;
                }

                if (log_history and options.history.text_log2_capacity > 0 and options.history.entries_log2_capacity > 0) {
                    // Get the length of the message
                    const message_len = std.fmt.count(format, args);

                    // Attempt to get a contiguous buffer big enough for the message
                    var buf = text.addManyAsSlice(message_len);
                    popOverlappingEntries(buf);

                    // If the buffer is too small, we may have wrapped the ring. Try again, if it's
                    // still too small our message is bigger than the entire ring and we'll just
                    // truncate it.
                    if (buf.len < message_len) {
                        buf = text.addManyAsSlice(message_len);
                        popOverlappingEntries(buf);
                    }

                    // Write the formatted message to the buffer
                    _ = std.fmt.bufPrint(buf, format, args) catch |err| switch (err) {
                        error.NoSpaceLeft => {}, // Allow truncation
                    };

                    // Send this log to Tracy
                    tracy.message(.{
                        .text = buf,
                        .color = switch (message_level) {
                            .err => .red,
                            .warn => .yellow1,
                            .info => .light_green,
                            .debug => .purple,
                        },
                    });

                    // Add this log to the list of entries. If there are line breaks, break it up
                    // into multiple entries--this makes it easier on log viewers which want to only
                    // render the visible parts of logs by making log entries have a fixed line
                    // height.
                    var lines = std.mem.splitScalar(u8, buf, '\n');
                    while (lines.next()) |line| {
                        entries.append(.{
                            .level = message_level,
                            .scope = @tagName(scope),
                            .message = line,
                            .time_ms = time_ms,
                        });
                    }
                }

                if (log_writer) {
                    if (writer) |w| {
                        // Try to write to the given writer, but ignore errors since there's nothing
                        // useful we can do if these writes fail. If we're logging a warning or
                        // error, flush since we might be about to crash.
                        w.print("{s}({s}, 0x{x}): ", .{
                            message_level.asText(),
                            @tagName(scope),
                            time_ms,
                        }) catch {};
                        w.print(format, args) catch {};
                        w.writeByte('\n') catch {};
                        switch (message_level) {
                            .err, .warn => w.flush() catch {},
                            .info, .debug => {},
                        }
                    }
                }
            }
        }

        fn buffersOverlap(a: []const u8, b: []const u8) bool {
            const a_start = @intFromPtr(a.ptr);
            const b_start = @intFromPtr(b.ptr);
            if (a_start < b_start and a_start + a.len <= b_start) return false;
            if (b_start < a_start and b_start + b.len <= a_start) return false;
            return true;
        }

        /// Pops all entries that point to text overlapping this buffer.
        fn popOverlappingEntries(buf: []const u8) void {
            while (entries.len > 0) {
                const index = entries.index(0);
                const entry = entries.items[index];
                if (buffersOverlap(entry.message, buf)) {
                    entries.pop();
                } else break;
            }
        }
    };
}

fn expectEntryEqual(expected: ?Entry, found: ?*const Entry) !void {
    try std.testing.expectEqual(expected == null, found == null);
    if (expected == null) return;
    try std.testing.expectEqualStrings(expected.?.message, found.?.*.message);
    try std.testing.expectEqualStrings(expected.?.scope, found.?.*.scope);
    try std.testing.expectEqual(expected.?.level, found.?.*.level);
}

test "writer" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var buf_writer: std.Io.Writer.Allocating = .fromArrayList(
        std.testing.allocator,
        &buf,
    );
    defer buf_writer.deinit();
    const L = Logger(.{
        .history = .none,
    });
    L.writer = &buf_writer.writer;
    L.logFn(.info, .scope, "Hello, {s}!", .{"World"});
    try std.testing.expectStringEndsWith(buf_writer.written(), "): Hello, World!\n");
    try std.testing.expectStringStartsWith(buf_writer.written(), "info(scope, 0x");
}

test "simple history" {
    const L = Logger(.{
        .history = .{
            .entries_log2_capacity = 4,
            .text_log2_capacity = 13,
        },
    });
    try expectEntryEqual(null, L.getEntry(0));

    L.logFn(.info, .scope, "Hello, {s}!", .{"World"});
    try expectEntryEqual(Entry{
        .level = .info,
        .scope = "scope",
        .message = "Hello, World!",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(null, L.getEntry(1));

    L.logFn(.warn, .scope2, "This is a test!", .{});
    try expectEntryEqual(Entry{
        .level = .info,
        .scope = "scope",
        .message = "Hello, World!",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope2",
        .message = "This is a test!",
        .time_ms = undefined,
    }, L.getEntry(1).?);
    try expectEntryEqual(null, L.getEntry(2));
}

test "wrapping entries" {
    const L = Logger(.{
        .history = .{
            .entries_log2_capacity = 2,
            .text_log2_capacity = 13,
        },
    });
    try expectEntryEqual(null, L.getEntry(0));

    L.logFn(.info, .scope, "This is the first {s}", .{"message"});
    L.logFn(.warn, .scope2, "This is message {}!", .{2});
    L.logFn(.err, .scope3, "This is message three", .{});
    L.logFn(.debug, .scope4, "This is message four", .{});
    L.logFn(.warn, .scope5, "This message should wrap{s}", .{"!!!"});
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope2",
        .message = "This is message 2!",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(Entry{
        .level = .err,
        .scope = "scope3",
        .message = "This is message three",
        .time_ms = undefined,
    }, L.getEntry(1).?);
    try expectEntryEqual(Entry{
        .level = .debug,
        .scope = "scope4",
        .message = "This is message four",
        .time_ms = undefined,
    }, L.getEntry(2).?);
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope5",
        .message = "This message should wrap!!!",
        .time_ms = undefined,
    }, L.getEntry(3).?);
    try expectEntryEqual(null, L.getEntry(4));
}

test "wrapping text" {
    const L = Logger(.{
        .history = .{
            .entries_log2_capacity = 13,
            .text_log2_capacity = 2,
        },
    });
    try expectEntryEqual(null, L.getEntry(0));

    L.logFn(.info, .scope1, "a", .{});
    L.logFn(.warn, .scope2, "b", .{});
    L.logFn(.debug, .scope3, "c", .{});
    L.logFn(.err, .scope4, "d", .{});
    try expectEntryEqual(Entry{
        .level = .info,
        .scope = "scope1",
        .message = "a",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope2",
        .message = "b",
        .time_ms = undefined,
    }, L.getEntry(1).?);
    try expectEntryEqual(Entry{
        .level = .debug,
        .scope = "scope3",
        .message = "c",
        .time_ms = undefined,
    }, L.getEntry(2).?);
    try expectEntryEqual(Entry{
        .level = .err,
        .scope = "scope4",
        .message = "d",
        .time_ms = undefined,
    }, L.getEntry(3).?);
    try expectEntryEqual(null, L.getEntry(4));

    // This wraps the text buffer and invalidates the oldest log
    L.logFn(.warn, .scope5, "e", .{});
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope2",
        .message = "b",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(Entry{
        .level = .debug,
        .scope = "scope3",
        .message = "c",
        .time_ms = undefined,
    }, L.getEntry(1).?);
    try expectEntryEqual(Entry{
        .level = .err,
        .scope = "scope4",
        .message = "d",
        .time_ms = undefined,
    }, L.getEntry(2).?);
    try expectEntryEqual(Entry{
        .level = .warn,
        .scope = "scope5",
        .message = "e",
        .time_ms = undefined,
    }, L.getEntry(3).?);
    try expectEntryEqual(null, L.getEntry(4));

    // The second log here requests more contiguous space than we have at the end of the buffer,
    // resulting in us wrapping and invalidating the first one as well
    L.logFn(.err, .scope6, "12", .{});
    L.logFn(.info, .scope7, "34", .{});
    try expectEntryEqual(Entry{
        .level = .info,
        .scope = "scope7",
        .message = "34",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(null, L.getEntry(1));

    // If we write a log longer than the entire buffer, it gets truncated
    L.logFn(.debug, .scope8, "abcdefg", .{});
    try expectEntryEqual(Entry{
        .level = .debug,
        .scope = "scope8",
        .message = "abcd",
        .time_ms = undefined,
    }, L.getEntry(0).?);
    try expectEntryEqual(null, L.getEntry(1));
}

test {
    _ = @import("ring_buffer.zig");
}
