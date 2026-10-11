# pgen.zig

**Highly work-in-progress**: This repo is under development that it is not ready for use, even as a minimal parser generator.

This is an [LR parser generator](https://en.wikipedia.org/wiki/Compiler-compiler) for Zig.

It takes in a plain text file describing a programming language's grammar, then generates a parser (in Zig source code) for it!

A parser takes in a string and turns it into a parse tree for further processing. [LR](https://en.wikipedia.org/wiki/LR_parser) describes a class of parsers. Not all languages can be parsed by LR parsers, but it is sufficient for most programming languages (plus, there are ways to "dig holes" in the parser so that it can do more than what an LR parser in the strict sense can do). Currently only the LR(0) and SLR variants of LR family parsers are implemented (the simplest ones :) but LR(1)/LALR will be added in the future.

## Building

Just do `zig build`. Current Zig version is 0.15 (will be ported to higher version soon).

The input of pgen.zig (which describes a language) is itself a language! So pgen.zig uses itself to parse its own input. Of course, there is a chicken-and-egg problem here so the first parser used to bootstrap pgen.zig was derived from a hand-translation of the grammar into pgen.zig's own internal representation (a `Cfg`, representing an already-parsed [context-free grammar](https://en.wikipedia.org/wiki/Context-free_grammar)). Despite calling it "hand-translation", the `Cfg` was actually emitted by `src/bootstrap/generate_meta_cfg.zig` during the build process. Then `src/bootstrap/generate_meta_parser.zig` generates the parser from the generated `Cfg` and a selected subset of the pgen.zig library (the "core"). The generated parser is then combined with the core to form the final pgen.zig library. `build.zig` handles all this mess automatically.

### The Web Demo

To build the in-browser demo you need Python (3.10+). Just run `demo/build.py` from the repo root, and the built website is in `demo/dist`. You can then use any software you like to serve the contents in it. Since we're already using Python, you can do `python -m http.server -d demo/dist` then navigate to `localhost:8000` in your browser to view the demo.
