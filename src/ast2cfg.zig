/// Convert EBNF AST to CFG.
///
/// Internal details:
/// The trivial way is to add an auxiliary nonterminal for every used AST node
/// that is not already a nonterminal or terminal; but we can definitely
/// optimize away some of these auxiliary nonterminals (aux nt). Example:
///
/// ```text
/// a: X Y | Z X
/// b: X Y | Y
/// ```
///
/// Without optimization, we'd create auxiliary nonterminals for "X Y", "Z X",
/// "X Y | Z X" and "X Y | Y", when only the one for "X Y" is somewhat
/// necessary (otherwise we must repeat "X Y" twice in CFG).
///
/// There are mainly two types of nodes which allow optimization *on its children*:
/// `.zero_or_more` and `.choose`. A `.zero_or_more` having a `.concat` operand
/// allow the `.concat` to introduce no aux nt. Any children of a `.choose`
/// does not require an aux nt. Of course, a `.zero_or_more` may be nested in
/// a `.choose` in which case we can optimize away `.zero_or_more`'s operand at
/// the same time. We don't handle recursive `.choose` since the AST interning
/// should have normalized (flattened) it.
///
/// We do 2 passes. In pass 1, determine how many times each interned AST node
/// gets used (on the right hand side of an EBNF production). In pass 2, we
/// actually convert, making sure not to introduce aux nts for nodes that have
/// only 1 use, AND meet the above condition.
const std = @import("std");
const cfg = @import("./cfg.zig");
const ast = @import("./ast.zig");

/// Managed `cfg.Cfg` with an arena allocator owning all memory.
pub const CfgManaged = struct {
    cfg: cfg.Cfg,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
