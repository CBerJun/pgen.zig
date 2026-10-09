//! Abstract syntax tree for a grammar (EBNF)
const std = @import("std");
const cfg = @import("./cfg.zig");

/// Less than comparison function to sort by pointer's numeric value.
/// Works well if you just need an arbitrary ordering between unique objects.
fn ascPtr(comptime T: type) fn (void, *const T, *const T) bool {
    return struct {
        pub fn inner(_: void, a: *const T, b: *const T) bool {
            return @intFromPtr(a) < @intFromPtr(b);
        }
    }.inner;
}

/// Abstract structure for a right hand side expression. Not intended for
/// mutation once initialized. Subexpressions are *borrowed* to facilitate
/// expression interning (see `ExprPool`), but buffer of slices are owned.
/// All the pointers representing subexpressions are supposed to be pointing to
/// an interned instance.
pub const Expr = union(enum) {
    nonterminal: u32,
    terminal: u32,
    concat: []*const Expr,
    zero_or_more: *const Expr,
    one_or_more: *const Expr,
    choose: []*const Expr,
    epsilon: void,

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .nonterminal, .terminal, .epsilon, .zero_or_more, .one_or_more => {},
            .concat, .choose => |slice| {
                allocator.free(slice);
            },
        }
        self.* = undefined;
    }

    /// Compare two `Expr`s whose subexpressions are interned structurally.
    pub fn internedEql(self: @This(), other: @This()) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other))
            return false;
        return switch (self) {
            .epsilon => true,
            inline .nonterminal, .terminal, .zero_or_more, .one_or_more => |val, tag| val == @field(other, @tagName(tag)),
            inline .concat, .choose => |slice, tag| std.mem.eql(*const Expr, slice, @field(other, @tagName(tag))),
        };
    }

    /// Hash using identity (pointer) for sub-expressions; so sub-expressions
    /// would have to be interned for this to be useful.
    pub fn internedHash(self: @This()) u64 {
        return switch (self) {
            .epsilon => 0x20260702, // Magic hash value ^_^
            .nonterminal, .terminal => |x| std.hash.int(x),
            .zero_or_more, .one_or_more => |ptr| std.hash.int(@intFromPtr(ptr)),
            .concat, .choose => |slice| blk: {
                comptime std.debug.assert(std.meta.hasUniqueRepresentation(std.meta.Elem(slice)));
                break :blk std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(slice));
            },
        };
    }
};

/// A pool of `Expr`s. In the pool, each `Expr` that is structurally equivalent
/// is normalized to a single instance of `Expr` that is owned by the pool.
/// This is called interning. The benefit is, we can compare two `Expr`s for
/// structural equivalence in O(1) using a single pointer comparison, and
/// naturally we obtain an ordering for the `Expr`s in case sorting is required
/// (e.g. A | B is same as B | A).
pub const ExprPool = struct {
    allocator: std.mem.Allocator,
    hashmap: std.HashMapUnmanaged(*const Entry, void, HashContext, std.hash_map.default_max_load_percentage),
    entries: std.ArrayListUnmanaged(Entry),

    /// An entry in the pool representing one `Expr`. It contains extra
    /// objects used during AST-to-CFG.
    pub const Entry = struct {
        expr: Expr,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.expr.free(allocator);
            self.* = undefined;
        }
    };

    /// Hash context used by `hashmap`.
    const HashContext = struct {
        pub fn eql(_: @This(), lhs: *const Entry, rhs: *const Entry) bool {
            return lhs.expr.internedEql(rhs.expr);
        }
        pub fn hash(_: @This(), key: *const Entry) u64 {
            return key.expr.internedHash();
        }
    };

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .hashmap = .empty,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.hashmap.deinit(self.allocator);
        self.* = undefined;
    }

    /// Hash context used to put an `Expr` (potentially non-interned but with
    /// all sub-expressions interned) into `self.hashmap`.
    const PutHashContext = struct {
        pub fn eql(_: @This(), key: Expr, test_key: *const Entry) bool {
            return key.internedEql(test_key.expr);
        }
        pub fn hash(_: @This(), key: Expr) u64 {
            return key.internedHash();
        }
    };

    /// `expr` must use `self.allocator`. Return a borrowed reference
    /// to the interned expr owned by the pool. The ownership of the expr
    /// passed in is destroyed or transferred to the pool.
    pub fn intern(self: *@This(), expr: Expr) std.mem.Allocator.Error!*const Expr {
        const gop = try self.hashmap.getOrPutAdapted(self.allocator, expr, PutHashContext{});
        if (gop.found_existing) {
            expr.free(self.allocator);
        } else {
            gop.key_ptr.* = try self.newEntry(expr);
        }
        return &gop.key_ptr.*.expr;
    }

    /// Get the internal entry corresponding to an *interned* `Expr`.
    /// (Unchecked) illegal behavior is invoked if expression is not interned
    /// in this pool.
    pub fn getEntry(_: @This(), interned_expr: *const Expr) *Entry {
        return @fieldParentPtr("expr", interned_expr);
    }

    fn newEntry(self: *@This(), expr: Expr) std.mem.Allocator.Error!*Entry {
        const entry_ptr = try self.entries.addOne(self.allocator);
        entry_ptr.expr = expr;
        return entry_ptr;
    }

    pub fn makeEpsilon(self: *@This()) std.mem.Allocator.Error!*const Expr {
        return self.intern(.{ .epsilon = void{} });
    }

    pub fn makeNonterminal(self: *@This(), nt: u32) std.mem.Allocator.Error!*const Expr {
        return self.intern(.{ .nonterminal = nt });
    }

    pub fn makeTerminal(self: *@This(), tid: u32) std.mem.Allocator.Error!*const Expr {
        return self.intern(.{ .terminal = tid });
    }

    pub fn makeOptional(self: *@This(), inner: *const Expr) std.mem.Allocator.Error!*const Expr {
        return switch (inner.*) {
            .epsilon, .zero_or_more => inner, // epsilon? = epsilon, X*? = X*
            .one_or_more => |x| self.makeZeroOrMore(x), // X+? = X*
            else => blk: {
                const buf = try self.allocator.alloc(*const Expr, 2);
                errdefer self.allocator.free(buf);
                buf = .{ inner, try self.makeEpsilon() };
                break :blk self.makeChoose(buf);
            },
        };
    }

    pub fn makeZeroOrMore(self: *@This(), inner: *const Expr) std.mem.Allocator.Error!*const Expr {
        return switch (inner.*) {
            .epsilon, .zero_or_more => inner, // epsilon* = epsilon, X** = X*
            .one_or_more => |x| self.makeZeroOrMore(x), // X+* = X*
            else => self.intern(.{ .zero_or_more = inner }),
        };
    }

    pub fn makeOneOrMore(self: *@This(), inner: *const Expr) std.mem.Allocator.Error!*const Expr {
        return switch (inner.*) {
            .epsilon, .one_or_more => inner, // epsilon+ = epsilon, X++ = X+
            .zero_or_more => |x| self.makeZeroOrMore(x), // X*+ = X*
            else => self.intern(.{ .one_or_more = inner }),
        };
    }

    /// Ownership of `operands` is transferred to this function, even if this
    /// function fails. `operands` must be allocated by `self.allocator`.
    pub fn makeConcat(self: *@This(), operands: []*const Expr) std.mem.Allocator.Error!*const Expr {
        // Remove epsilons (two pointer)
        var i: usize = 0;
        var j: usize = operands.len;
        var num_inner: usize = 0;
        var free_operands = true;
        defer if (free_operands) self.allocator.free(operands);
        while (i < j) {
            if (operands[i] == .epsilon) {
                std.mem.swap(*const Expr, &operands[i], &operands[j - 1]);
                j -= 1;
            } else {
                num_inner += switch (operands[i].*) {
                    // The inner concat must have been interned & normalized,
                    // so slice.len >1.
                    .concat => |slice| slice.len,
                    else => 1,
                };
                i += 1;
            }
        }
        // `j` is now number of operands after removing epsilons.
        if (j == 0)
            return self.makeEpsilon();
        if (j == 1)
            return operands[0];
        var inners: []*const Expr = undefined;
        if (num_inner != j) {
            // There is some subexpression that is a `.concat`.
            std.debug.assert(num_inner > j);
            inners = try self.allocator.alloc(num_inner);
            errdefer self.allocator.free(inners);
            var l: usize = 0;
            for (operands[0..j]) |operand| {
                switch (operand.*) {
                    .concat => |slice| {
                        @memcpy(inners[l..][0..slice.len], slice);
                        l += slice.len;
                    },
                    else => {
                        inners[l] = operand;
                        l += 1;
                    },
                }
            }
            std.debug.assert(l == num_inner);
        } else {
            if (operands.len == j) {
                inners = operands;
            } else {
                std.debug.assert(operands.len < j); // Due to epsilons deleted
                inners = try self.allocator.realloc(operands, j);
            }
            free_operands = false;
        }
        std.mem.sortUnstable(*const Expr, inners, void{}, ascPtr(Expr));
        return self.intern(.{ .concat = inners });
    }

    /// Ownership of `operands` is transferred to this function, even if this
    /// function fails. `operands` must be allocated by `self.allocator`.
    pub fn makeChoose(self: *@This(), operands: []*const Expr) std.mem.Allocator.Error!*const Expr {
        std.debug.assert(operands.len != 0);
        // Expand any operand that is a `.choose`
        var num_inner: usize = 0;
        var nullable = false; // has `.zero_or_more` or `.epsilon`
        var has_repeat = false; // has `.zero_or_more` or `.one_or_more`
        var free_operands = true;
        defer if (free_operands) self.allocator.free(operands);
        for (operands) |operand| {
            num_inner += switch (operand.*) {
                // The inner concat must have been interned & normalized,
                // so slice.len >1.
                .choose => |slice| slice.len,
                else => 1,
            };
            switch (operand.*) {
                .epsilon, .zero_or_more => nullable = true,
                else => {},
            }
            switch (operand.*) {
                .zero_or_more, .one_or_more => has_repeat = true,
                else => {},
            }
        }
        var inners: []*const Expr = undefined;
        if (num_inner != operands.size) {
            // Some operand(s) are `.choose` and need to be expanded.
            std.debug.assert(num_inner > operands.size);
            // XXX It's possible to realloc `operands` to size of `num_inner`
            // here but need to expand backwards that way.
            inners = try self.allocator.alloc(num_inner);
            errdefer self.allocator.free(inners);
            var l: usize = 0;
            for (operands) |operand| {
                switch (operand.*) {
                    .choose => |slice| {
                        @memcpy(inners[l..][0..slice.len], slice);
                        l += slice.len;
                    },
                    else => {
                        inners[l] = operand;
                        l += 1;
                    },
                }
            }
            std.debug.assert(l == num_inner);
        } else {
            inners = operands;
            free_operands = false;
        }
        // From this point on, we will stick with the buffer `inners`, but
        // we may change its `.len`. `num_inner` is always the buffer size.
        var free_inners = true;
        defer if (free_inners) self.allocator.free(inners.ptr[0..num_inner]);
        // Normalize if nullable
        if (nullable) {
            var i: usize = 0;
            var j: usize = inners.len;
            while (i < j) {
                switch (inners[i]) {
                    .epsilon => {
                        // Epsilon is not needed if there is a `zero_or_more`.
                        if (has_repeat) {
                            j -= 1;
                            std.mem.swap(*const Expr, &inners[i], &inners[j]);
                        }
                    },
                    .one_or_more => |content| {
                        // One or more becomes zero or more
                        inners[i] = try self.makeZeroOrMore(content);
                        i += 1; // We shouldn't need to handle inners[i] again.
                    },
                    else => i += 1,
                }
            }
            inners.len = j;
        }
        // Sort and remove duplicate operands
        std.mem.sortUnstable(*const Expr, inners, void{}, ascPtr(Expr));
        var last_operand: usize = 0; // address 0 is never mapped
        var write_index: usize = 0;
        var found_gap = false; // In most cases there is no duplicate; const optimization
        for (inners) |*operand_ptr| {
            const operand = @intFromPtr(operand_ptr.*);
            if (operand != last_operand) {
                if (found_gap)
                    std.mem.swap(*const Expr, &inners[write_index], operand_ptr);
                write_index += 1;
                last_operand = operand;
            } else {
                found_gap = true;
            }
        }
        inners.len = write_index;
        // Only 1 option special case
        std.debug.assert(inners.len > 0);
        if (inners.len == 1)
            return inners[0];
        // Adjust buffer size to match actual length
        const realloc_buffer = try self.allocator.realloc(inners.ptr[0..num_inner], inners.len);
        free_inners = false;
        return self.intern(.{ .choose = realloc_buffer });
    }
};

/// Intermediate form of grammar, still in EBNF style.
pub const Ebnf = struct {
    /// Labelling of terminals. This will pass down as is to the `cfg.Cfg`
    /// object. Thus, the terminal labelling is the same between an `Ebnf`
    /// and the corresponding `cfg.Cfg`.
    terminals: cfg.Terminals,
    /// Labelling of nonterminals. This will pass down to the `cfg.Cfg` object
    /// but auxiliary nonterminals may be added during EBNF-to-CFG. Those aux
    /// nts always use new IDs and so existing nts' IDs won't change.
    nonterminals: cfg.Nonterminals,
    /// The EBNF production associated with each nt. Length is
    /// `nonterminals.count`.
    productions: [*]*const Expr,
};
