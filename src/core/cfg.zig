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
    count: u32,
    /// All productions. Each production is a slice of `Symbol` representing
    /// the RHS. See `pact` for info on LHS.
    rhs: [*]const []const Symbol,
    /// `rhs` is split into contiguous subarrays such that the LHS
    /// within each subarray are the same. In particular, the subarray for
    /// nonterminal 0 is first, then 1, then 2, ... This stores the starting
    /// index of subarray of each nonterminal. Length is always
    /// `nonterminals.count`.
    pact: [*]const u32,
    /// LHS nonterminal of each production. This information is redundant but
    /// saves a binary search for each query.
    lhs: [*]const u32,

    pub const Rule = struct {
        /// Production ID
        id: u32,
        /// LHS nonterminal
        lhs: u32,
        /// RHS production
        rhs: []const Symbol,
    };

    /// Iterate over a range of productions.
    pub const Iterator = struct {
        cur: u32,
        end: u32,
        owner: *const CfgProductions,

        pub fn next(self: *@This()) ?Rule {
            if (self.cur == self.end)
                return null;
            defer self.cur += 1;
            return .{
                .id = self.cur,
                .lhs = self.owner.lhs[self.cur],
                .rhs = self.owner.rhs[self.cur],
            };
        }
    };

    /// Iterate over all productions associated with a certain LHS.
    /// `self` must have a stable address!!
    pub fn of(self: *const @This(), symbol_spec: sym.SymbolSpec, nt: u32) Iterator {
        return .{
            .cur = self.pact[nt],
            .end = if (nt + 1 == symbol_spec.nonterminals.count) self.count else self.pact[nt + 1],
            .owner = self,
        };
    }

    pub fn get(self: @This(), production_id: u32) Rule {
        return .{
            .id = production_id,
            .lhs = self.lhs[production_id],
            .rhs = self.rhs[production_id],
        };
    }
};
