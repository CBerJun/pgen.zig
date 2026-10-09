/// Collection of all possible literal values for a certain suffix
/// e.g. "spam"k, "ham"k => suffix = "k", literals = ["spam", "ham"]
pub const LiteralCollection = struct {
    suffix: []const u8,
    literals: []const []const u8,
};

/// A terminal or nonterminal
pub const Symbol = union(enum) {
    terminal: u32,
    nonterminal: u32,
};

/// Describe terminal alphabet in a CFG.
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

/// Describe nonterminal alphabet in a CFG.
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

/// Intermediate form of grammar in which EBNF constructs have been flattened.
/// Instances of this struct are not intended to be mutated.
pub const Cfg = struct {
    /// Labelling of terminals.
    terminals: Terminals,
    /// Labelling of nonterminals.
    nonterminals: Nonterminals,

    /// Number of productions
    total_productions: u32,
    /// All productions. Each production is a slice of `Symbol` representing
    /// the RHS. See `production_pact` for info on LHS.
    productions: [*]const []const Symbol,
    /// `productions` is split into contiguous subarrays such that the LHS
    /// within each subarray are the same. In particular, the subarray for
    /// nonterminal 0 is first, then 1, then 2, ... This stores the starting
    /// index of subarray of each nonterminal. Length is always
    /// `nonterminals.count`.
    production_pact: [*]const u32,
    /// LHS nonterminal of each production. This information is redundant but
    /// saves a binary search for each query.
    production_lhs: [*]const u32,

    /// Get ending index of subarray for `nt` in `self.productions` (exclusive)
    pub fn productionEndIndexOf(self: @This(), nt: u32) u32 {
        return if (nt + 1 == self.nonterminals.count) self.total_productions else self.production_pact[nt + 1];
    }

    /// Return all productions associated with a certain LHS
    pub fn productionsOf(self: @This(), nt: u32) []const []const Symbol {
        return self.productions[self.production_pact[nt]..self.productionEndIndexOf(nt)];
    }
};
