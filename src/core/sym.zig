//! Symbols related definitions, common to AST (EBNF) and CFG forms.
//! Nonterminals, terminals, entry, etc.

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
    /// Nonterminal names given by user. Length is always
    /// `node_forming_count`. We don't store names for nodeless
    /// nonterminals.
    names: [*]const []const u8,

    /// Check if a nonterminal is node-forming
    pub fn isNodeForming(self: @This(), nt: u32) bool {
        return nt < self.node_forming_count;
    }
};
