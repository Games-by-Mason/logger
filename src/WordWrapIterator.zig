const std = @import("std");

const WordWrapIterator = @This();

index: ?usize,
max_line_len: u16,
buf: []const u8,

pub const Options = struct {
    max_line_len: u16,
};

pub fn init(buf: []const u8, options: Options) WordWrapIterator {
    return .{
        .index = 0,
        .buf = buf,
        .max_line_len = options.max_line_len,
    };
}

pub fn next(self: *WordWrapIterator) ?[]const u8 {
    const start = self.index orelse return null;
    var end = start;
    for (start..self.buf.len + 1) |i| {
        // Check if we're on whitespace
        if (i >= self.buf.len or std.ascii.isWhitespace(self.buf[i])) {
            // If the next word wouldn't fit, break before this word
            const len = i - start;
            if (len > self.max_line_len) {
                if (start == end) {
                    // There was no previous word, break mid word
                    end = start + self.max_line_len;
                    self.index = end;
                    return self.buf[start..end];
                } else {
                    // There was a previous word, break after it
                    self.index = end + 1;
                    return self.buf[start..end];
                }
            }

            // If we're on a newline, break here
            if (i < self.buf.len and self.buf[i] == '\n') {
                self.index = i + 1;
                return self.buf[start..i];
            }

            // Otherwise advance to the next word
            end = i;
        }
    }
    self.index = null;
    return self.buf[start..];
}

test WordWrapIterator {
    const buf = "The quick brown fox jumped over the lazy dog, and in doing so wrote a kinda sorta long test sentence for me to test my line break code out. Also the text containedsomeverylongsectionswithnospacestoseeifthatbrokeproperlyaswell, because it needed that, also some\nexplicit newlines\nas well.";
    var iter: WordWrapIterator = .init(buf, .{ .max_line_len = 20 });
    try std.testing.expectEqualStrings("The quick brown fox", iter.next().?);
    try std.testing.expectEqualStrings("jumped over the lazy", iter.next().?);
    try std.testing.expectEqualStrings("dog, and in doing so", iter.next().?);
    try std.testing.expectEqualStrings("wrote a kinda sorta", iter.next().?);
    try std.testing.expectEqualStrings("long test sentence", iter.next().?);
    try std.testing.expectEqualStrings("for me to test my", iter.next().?);
    try std.testing.expectEqualStrings("line break code out.", iter.next().?);
    try std.testing.expectEqualStrings("Also the text", iter.next().?);
    try std.testing.expectEqualStrings("containedsomeverylon", iter.next().?);
    try std.testing.expectEqualStrings("gsectionswithnospace", iter.next().?);
    try std.testing.expectEqualStrings("stoseeifthatbrokepro", iter.next().?);
    try std.testing.expectEqualStrings("perlyaswell, because", iter.next().?);
    try std.testing.expectEqualStrings("it needed that, also", iter.next().?);
    try std.testing.expectEqualStrings("some", iter.next().?);
    try std.testing.expectEqualStrings("explicit newlines", iter.next().?);
    try std.testing.expectEqualStrings("as well.", iter.next().?);
    try std.testing.expectEqual(null, iter.next());
}
