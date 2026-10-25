const sym = @import("./sym.zig");

/// A terminal or nonterminal
pub const Symbol = union(enum) {
    terminal: u32,
    nonterminal: u32,
};

/// Intermediate form of grammar in which EBNF constructs have been flattened.
/// Instances of this struct are not intended to be mutated.
/// Together with `sym.SymbolSpec` they form the CFG intermediate form. They
/// are separate due to memory management consideration.
pub const CfgProductions = struct {
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
    pub fn productionEndIndexOf(self: @This(), symbol_spec: sym.SymbolSpec, nt: u32) u32 {
        return if (nt + 1 == symbol_spec.nonterminals.count) self.total_productions else self.production_pact[nt + 1];
    }

    /// Return all productions associated with a certain LHS
    pub fn productionsOf(self: @This(), symbol_spec: sym.SymbolSpec, nt: u32) []const []const Symbol {
        return self.productions[self.production_pact[nt]..self.productionEndIndexOf(symbol_spec, nt)];
    }
};
