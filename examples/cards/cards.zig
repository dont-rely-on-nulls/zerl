const std = @import("std");
const zerl = @import("zerl");

const Suit = enum {
    clubs,
    diamonds,
    hearts,
    spades,
};

const Value = enum {
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    @"10",
    jack,
    queen,
    king,
    ace,
};

const Card_Tag = enum { card };
const Card = struct {
    Card_Tag,
    Value,
    Suit,
};

const Message = union(enum) {
    hello: *const zerl.ei.erlang_pid,
    say: []const u8,
    integer: i32,
    double: f64,
    shuffle: []const Card,
    bye: void,
};

const Message_Tag = @typeInfo(Message).Union.tag_type.?;

const Dealer_Error = enum {
    unknown_message,
    invalid_message,
    some_other_error,
};

const Reply = union(enum) {
    say: [:0]const u8,
    halved: i31,
    shuffled: []Card,
    ok: void,
    @"error": Dealer_Error,
};

const deck: [52]Card = blk: {
    var cards: [4][13]Card = undefined;
    for (@typeInfo(Suit).Enum.fields, 0..) |suit_field, suit_index| {
        const suit: Suit = @enumFromInt(suit_field.value);
        for (@typeInfo(Value).Enum.fields, 0..) |value, value_index| {
            cards[suit_index][value_index] = .{ .card, @enumFromInt(value.value), suit };
        }
    }
    break :blk @bitCast(cards);
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const stderr = std.io.getStdErr().writer();

    try stderr.print("Running cards example...\n", .{});

    if (zerl.ei.ei_init() != 0) return error.ei_init_failed;
    var node = try zerl.Node.init("cards_cookie");
    try zerl.establish_connection(&node, "cards", "localhost");

    try stderr.print("Connected.\n", .{});

    const messages = [_]Message{
        .{ .hello = try node.self() },
        .{ .say = "Hello, world!" },
        .{ .integer = 42 },
        .{ .double = 413 },
        .{ .shuffle = &deck },
        .{ .shuffle = &deck },
        .{ .shuffle = &deck },
        .{ .shuffle = &deck },
        .bye,
    };
    for (messages) |message| {
        try stderr.print("\nMessage: {}\n", .{message});
        try node.send("dealer", message);
        const reply = try node.receive(Reply, allocator);
        try stderr.print("\nReply: {}\n", .{reply});
    }
}
