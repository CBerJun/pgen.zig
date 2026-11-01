//! Symbols related definitions, common to AST (EBNF) and CFG forms.
//! Nonterminals, terminals, entry, etc.
const std = @import("std");

/// Labelling of nonterminals and terminals.
pub const SymbolSpec = struct {
    terminals: Terminals,
    nonterminals: Nonterminals,
};

/// Describe terminal alphabet in a CFG/EBNF.
pub const Terminals = struct {
    /// Terminals enclosed in quotes, optionally with a suffix
    literal: []const LiteralCollection,
    /// Terminals with a name
    named: []const []const u8,
    /// Special End of Input terminal. This token must not appear in any
    /// production. The augmented rule (S' -> S $) is implicitly defined.
    eoi: u32,
    /// Total terminals. This is redundant but it takes some time to
    /// recompute it. Includes the special End of Input terminal.
    count: u32,

    // Terminals are labelled starting from 0 in order they appear in
    // `literal`, then the `named`. `eoi` is always `count - 1`.
};

/// Collection of all possible literal values for a certain suffix
/// e.g. "spam"k, "ham"k => suffix = "k", literals = ["spam", "ham"]
pub const LiteralCollection = struct {
    suffix: []const u8,
    literals: []const []const u8,
};

/// Describe nonterminal alphabet in a CFG/EBNF.
pub const Nonterminals = struct {
    /// Entry nonterminal. Must be node-forming.
    entry: u32,
    /// Number of nonterminals
    count: u32,
    /// Number of node-forming nonterminals (those defined by the user and
    /// without `nodeless` qualifier; they form tree nodes in CST). These
    /// nonterminals are always labelled from 0 to this quantity minus 1.
    node_forming_count: u32,
    /// Nonterminal names given by user. Length is always `node_forming_count`.
    names: [*]const []const u8,

    /// Check if a nonterminal is node-forming
    pub fn isNodeForming(self: @This(), nt: u32) bool {
        return nt < self.node_forming_count;
    }
};

/// Additional facts in a `SymbolSpec` for diagnostic purposes. The meta CFG
/// does not include this, so this struct follows the usual memory management
/// scheme.
pub const DiagnosticInfo = struct {
    /// Names for nodeless nts. Length is <= `count - node_forming_count`.
    nodeless_nt_names: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, nodeless_nt_count: u32) std.mem.Allocator.Error!@This() {
        var self: @This() = .{
            .nodeless_nt_names = &.{},
            .allocator = allocator,
        };
        errdefer self.deinit();
        self.nodeless_nt_names = try allocator.alloc([]const u8, nodeless_nt_count);
        // Fill with empty slice to allow deinit to clean up properly.
        @memset(self.nodeless_nt_names, &[0]u8{});
        return self;
    }

    pub fn deinit(self: *@This()) void {
        for (self.nodeless_nt_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.nodeless_nt_names);
    }
};
