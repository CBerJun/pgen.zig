# pgen.zig

**Highly work-in-progress**: This repo is under development that it is not ready for use, even as a minimal parser generator.

This is an [LR parser generator](https://en.wikipedia.org/wiki/Compiler-compiler) for Zig.

It takes in a plain text file describing a programming language's grammar, then generates a parser (in Zig source code) for it!

A parser takes in a string and turns it into a parse tree for further processing. [LR](https://en.wikipedia.org/wiki/LR_parser) describes a class of parsers. Not all languages can be parsed by LR parsers, but it is sufficient for most programming languages (plus, there are ways to "dig holes" in the parser so that it can do more than what an LR parser in the strict sense can do). Currently only the LR(0) and SLR variants of LR family parsers are implemented (the simplest ones :) but LR(1)/LALR will be added in the future.

The input of pgen.zig (which describes a language) is itself a language! So pgen.zig uses itself to parse its own input. Of course, there is a chicken-and-egg problem here so the first parser used to bootstrap pgen.zig was hand-translated into pgen.zig's own internal representation (a `Cfg`) of a *parsed* language spec. Despite calling it "hand-translation", the `Cfg` was actually emitted by a Python script at `tools/generate_meta_cfg.py`.

So to build this you need Python (3.10 or above).
