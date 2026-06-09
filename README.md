# LL-Parsing

A Swift library implementing a deterministic, top-down **LL(1)** parser. Given any context-free grammar (loaded from BNF, EBNF, WSN, or `.gen` notation), the parser builds a concrete **parse tree** for valid input sentences, or throws a structured `ParseError` on failure.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)  
[![Platforms](https://img.shields.io/badge/platforms-macOS%2011%20%7C%20iOS%2014-blue.svg)](https://developer.apple.com/swift/)  
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)  

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Core Components](#core-components)
   - [LLParser](#llparser)
   - [Parser Protocol](#parser-protocol)
   - [SyntaxTree](#syntaxtree)
   - [SyntaxError](#syntaxerror)
   - [SyntaxTreePrinter & Graphviz](#syntaxtreeprinter--graphviz)
   - [ParserLogger](#parserlogger)
- [LL(1) Algorithm in Depth](#ll1-algorithm-in-depth)
   - [FIRST and FOLLOW Sets](#first-and-follow-sets)
   - [Prediction Function](#prediction-function)
   - [Parse Stack and Result Stack](#parse-stack-and-result-stack)
   - [Tree Construction](#tree-construction)
- [Grammar Notations Supported](#grammar-notations-supported)
- [Command-Line Tool (gtool)](#command-line-tool-gtool)
- [Usage Examples](#usage-examples)
- [Extending the Parser](#extending-the-parser)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [License](#license)
---

## Overview

LL(1) parsing is a **top-down, predictive** parsing strategy in which the parser expands the leftmost non-terminal of the current sentential form by looking at exactly **one** token of lookahead. This makes it deterministic—there is never any backtracking—and extremely efficient: parsing runs in **O(n)** time relative to the length of the input.

The library is structured as a Swift package with two targets:

| Target | Type | Purpose |  
|--------|------|---------|  
| `LL-Parsing` | Library | Core parser, syntax-tree data structure, pretty-printer, Graphviz renderer |  
| `gtool` | Executable | Command-line interface for loading a grammar and parsing input |  

---

## Architecture

```
LL-Parsing/
├── Sources/
│   ├── LL-Parsing/
│   │   ├── Parser.swift              # Parser protocol + recognizes(_:) helper
│   │   ├── LLParser.swift            # LL(1) algorithm implementation
│   │   ├── ParserLogger.swift        # OSLog category "LL(1)"
│   │   └── Syntax-Tree/
│   │       ├── SyntaxTree.swift      # Generic recursive-enum tree + functional transforms
│   │       ├── SyntaxTreeError.swift # SyntaxError with line/column reporting
│   │       ├── SyntaxTreePrinter.swift  # ANSI-coloured ASCII tree printer
│   │       └── SyntaxTreeGraphviz.swift # DOT-language export
│   └── gtool/
│       ├── GrammarTool.swift         # @main ParsableCommand root
│       ├── Parse.swift               # `parse` sub-command
│       └── Definitions.swift         # Notation, Method, Analysis, Source enums
└── Tests/
    └── LL-ParsingTests/
        └── LL_ParsingTests.swift
```

The library depends on three sibling packages from the same author:

- **[Grammar](https://github.com/hakkabon/Grammar)** — `Grammar`, `Production`, `Symbol`, `Terminal`, `NonTerminal`, First/Follow computation, standard-form rewriting.
- **[GrammarTokenizer](https://github.com/hakkabon/GrammarTokenizer)** — `Tokenizer` and `ParserInput` wrapping the token stream.
- **[GrammarDiagram](https://github.com/hakkabon/GrammarDiagram)** — Railroad-diagram rendering (used by `gtool`).

---

## Core Components

### LLParser

`LLParser` is the heart of the library. It is a concrete `class` that conforms to the `Parser` protocol.

```swift
public class LLParser: Parser {
    public init(grammar: Grammar)
    public func syntaxTree(for string: String) throws -> ParseTree
}
```

**Initialisation** computes the **FIRST** and **FOLLOW** sets for the entire grammar once via `grammar.firstAndFollow()`, then groups productions by their goal non-terminal into a dictionary for O(1) lookup during parsing. The epsilon and EOF sentinel symbols are also cached at this point.

**`syntaxTree(for:)`** delegates to the private `parse(_:)` method, which runs the main LL(1) loop.

#### Internal stack item types

```swift
private enum StackItem {
    case symbol(Symbol)                          // a grammar symbol to expand or match
    case reduce(parent: NonTerminal, childCount: Int)  // a marker to assemble a tree node
}
```

The `.reduce` marker is the key mechanism for building the concrete parse tree without a separate tree-building pass.

---

### Parser Protocol

```swift
public protocol Parser {
    func syntaxTree(for string: String) throws -> ParseTree
}

public extension Parser {
    func recognizes(_ string: String) -> Bool
}
```

`recognizes(_:)` is a convenience wrapper: it calls `syntaxTree(for:)` and returns `true` if no error is thrown, making it easy to use the parser as a membership tester without catching errors.

```swift
let parser = LLParser(grammar: myGrammar)
if parser.recognizes("1 + 2 * 3") {
    print("Valid arithmetic expression")
}
```

---

### SyntaxTree

`SyntaxTree<Node, Leaf>` is a **generic recursive enum** with three cases:

```swift
public enum SyntaxTree<Node: Equatable, Leaf: Equatable> {
    case leaf(Leaf)
    case node(Node, children: [SyntaxTree<Node, Leaf>])
    case empty
}
```

For the parser, `ParseTree` is the specialisation:

```swift
public typealias ParseTree = SyntaxTree<NonTerminal, Range<String.Index>>
```

Leaf nodes carry a `Range<String.Index>` into the original source string, so no characters are copied until the caller explicitly maps them. The tree is materialised lazily:

```swift
let printableTree = try parser.syntaxTree(for: input)
    .mapLeafs { String(input[$0]) }
print(printableTree)
```

#### Functional transforms

| Method | Description |  
|--------|-------------|  
| `mapNodes(_:)` | Transform every inner node label |  
| `mapLeafs(_:)` | Transform every leaf value (e.g. `Range<String.Index>` → `String`) |  
| `filter(_:)` | Prune subtrees whose root does not satisfy a predicate |  
| `explode(_:)` | Inline a node's children into its parent |  
| `compressed()` | Collapse single-child nodes (useful for simplifying deep trees) |  
| `allNodes(where:)` | Collect all subtrees whose root satisfies a predicate |  
| `leafs` | Collect all leaf values in left-to-right order |  

All transforms respect the `.empty` case and propagate cleanly.

---

### SyntaxError

`SyntaxError` is a richly-typed struct (not used by `LLParser` directly, but available for error-reporting layers on top):

```swift
public struct SyntaxError: Error {
    public enum Reason {
        case emptyNotAllowed
        case unknownToken
        case unmatchedPattern
        case unexpectedToken
    }
    public let range: Range<String.Index>
    public let reason: Reason
    public let context: [NonTerminal]
    public let string: String
    public var line: Int    // 0-based
    public var column: Int  // 0-based
}
```

`LLParser` itself throws `ParseError` (a simpler enum with `runtimeError`, `tokenError`, `noTokenError`). `SyntaxError` is designed for richer error-recovery scenarios.

---

### SyntaxTreePrinter & Graphviz

**`SyntaxTreePrinter`** renders a parse tree as an ANSI-coloured ASCII box-drawing tree:

```
E
├── T
│   └── 1
└── Ex
    ├── +
    ├── T
    │   └── 2
    └── Ex
        └── ε
```

Colours: node labels in **bold**, leaf values in **green**, branch connectors in **blue**, and `.empty` in **gray**.

**`SyntaxTreeGraphviz`** exports the tree as a Graphviz DOT graph. The `gtool parse --analysis graph` command pipes this to `dot` and opens a PDF, making it straightforward to visualise large trees. Each node is assigned a unique integer ID to disambiguate identical labels in the same tree.

---

### ParserLogger

All parser activity is logged via Apple's `OSLog` framework under the subsystem `com.grammar.hakkabon` and category `LL(1)`:

```swift
Logger.ll.trace("Matched \(predictedSymbol) with current token \(currentToken.type).")
Logger.ll.warning("LL(1) conflict \(prediction!) vs \(production)")
```

Use **Console.app** or `log stream --predicate 'subsystem == "com.grammar.hakkabon"'` to observe the parser's decisions in real time. The `.trace` level logs every symbol match and prediction; `.warning` fires when an LL(1) ambiguity is detected.

---

## LL(1) Algorithm in Depth

### FIRST and FOLLOW Sets

The `Grammar.firstAndFollow()` method (from the Grammar package) runs two fixed-point iterations:

**FIRST(X):**
- If `X` is a terminal `a`, then `FIRST(X) = {a}`.
- If `X →* ε`, then `ε ∈ FIRST(X)`.
- If `X → Y₁ Y₂ … Yₙ`, the set accumulates tokens from each `FIRST(Yᵢ)` as long as the preceding symbols are nullable.

**FOLLOW(A):**
- `FOLLOW(start) = {EOF}`.
- For each production `B → α A β`: add `FIRST(β) − {ε}` to `FOLLOW(A)`.
- If `β ⇒* ε`, add `FOLLOW(B)` to `FOLLOW(A)`.

These sets are computed once at `LLParser` initialisation and reused for every call to `parse(_:)`.

---

### Prediction Function

```swift
private func predict(A: NonTerminal, token: Token) throws -> Production?
```

For a given non-terminal `A` and the current lookahead `token`, `predict` iterates over all productions `A → rule` and selects the unique one satisfying either:

1. **Token ∈ FIRST(rule)** — the lookahead is in the rule's First set, so this rule can start with it.
2. **ε ∈ FIRST(rule) AND Token ∈ FOLLOW(A)** — the rule is nullable and the token legally follows `A`.

If two productions match (i.e. the grammar is not LL(1) for this non-terminal/lookahead pair), a `Logger.ll.warning` is emitted and the first match is returned. This design surfaces conflicts without aborting, which aids grammar debugging.

---

### Parse Stack and Result Stack

The algorithm uses **two stacks** in parallel:

| Stack | Type | Role |  
|-------|------|------|  
| `parseStack` | `Stack<StackItem>` | Controls the parsing sequence (prediction + matching) |  
| `resultStack` | `[ParseTree]` | Accumulates completed subtrees for tree assembly |  

**Initialization:**
```
parseStack: [ EOF, <start> ]   (EOF at bottom, start symbol on top)
resultStack: []
```

**Main loop — three cases:**

1. **`.reduce(parent: A, childCount: n)`** — Pop `n` entries from `resultStack`, wrap them in `ParseTree.node(A, children:)`, and push back.
2. **`.symbol(.terminal(t))`** — Match `t` against the current token. On success, push `ParseTree.leaf(range)` to `resultStack` and advance the tokenizer.
3. **`.symbol(.nonTerminal(A))`** — Call `predict(A:token:)` to find the applicable production. Push a `.reduce` marker (processed last), then push the production's non-epsilon symbols in **reverse order** (so the first symbol is processed first).

When the loop pops the EOF terminal from the parse stack, the root of the tree is `resultStack[0]`.

**Example trace for grammar `E → T Ex; Ex → '+' T Ex | ε; T → 'n'` and input `n + n`:**

```
parseStack           resultStack      action
─────────────────    ─────────────    ──────────────────────────────
[EOF, E]             []               predict E → T Ex
[EOF, reduce(E,2), Ex, T]  []         predict T → 'n'
[EOF, reduce(E,2), Ex, reduce(T,1), 'n']  []  match 'n' → leaf
[EOF, reduce(E,2), Ex, reduce(T,1)]  [leaf]   reduce T(1) → node(T,[leaf])
[EOF, reduce(E,2), Ex]    [node(T)]   predict Ex → '+' T Ex
[EOF, reduce(E,2), reduce(Ex,3), Ex, T, '+']  [node(T)]  match '+' → leaf
… and so on …
```

---

### Tree Construction

The dual-stack approach ensures the tree is built **bottom-up within a top-down parse**, without a separate post-processing step:

1. Terminals become `ParseTree.leaf(range)` immediately on match.
2. The `.reduce` marker, pushed before the children of a production, fires only after all children have been matched and assembled into the `resultStack`. It then gathers exactly `childCount` entries from the top of `resultStack` and wraps them into a `ParseTree.node`.
3. Because `.reduce` is pushed *before* (and therefore processed *after*) the children, the child ordering is naturally preserved.

Epsilon productions produce a `.reduce` with `childCount = 0`, resulting in a `ParseTree.node(A, children: [])` — an explicit empty-derivation node.

---

## Grammar Notations Supported

`LLParser` accepts any `Grammar` object from the Grammar package, which can be constructed from four textual notations:

### BNF (Backus–Naur Form)
```
<E>  ::= <T> <Ex>
<Ex> ::= '+' <T> <Ex> | ε
<T>  ::= 'n'
```

### EBNF (Extended BNF — ISO/IEC 14977 style)
```
E  = T , Ex ;
Ex = '+' , T , Ex | ;
T  = 'n' ;
```

### WSN (Wirth Syntax Notation)
```
E  : T Ex
Ex : '+' T Ex | ε
T  : 'n'
```
WSN supports inline EBNF constructs:
- `[x]` — optional (zero or one)
- `{x}` — repetition (zero or more)
- `(a | b)` — grouping

These are automatically rewritten to standard BNF productions by `grammar.rewriteToStandardForm()`.

### `.gen` (Generic / Annotated)
```
> <E>
<E>  ::= <T> <Ex>
<Ex> ::= '+' <T> <Ex> | ε
<T>  ::= 'n'
```
The `> <start>` directive embeds the start symbol inside the file, so no `--start` flag is needed.

---

## Command-Line Tool (gtool)

```
OVERVIEW: A utility for parsing BNF grammars with a deterministic, top-down LL(1) parsing approach.

USAGE: gtool <subcommand>

SUBCOMMANDS:
  parse               Generate parse tree of input applied to given grammar.
```

### `gtool parse` options

```
USAGE: gtool parse --grammar <grammar> [--start <start>] [--method <method>]
                   [--input <input>] [--analysis <analysis>]

OPTIONS:
  -g, --grammar <grammar>   Grammar file (.bnf | .ebnf | .wsn | .gen)
  -s, --start <start>       Start non-terminal (not needed for .gen files)
  -m, --method <method>     Parsing method: ll (default: ll)
  -i, --input <input>       Input string or path to input file
  -a, --analysis <analysis> Output format: tree | graph (default: tree)
```

### Examples

```bash
# Parse the string "n+n" using the arithmetic grammar, display ASCII tree
gtool parse -g arithmetic.wsn -s E -i "n+n" -a tree

# Parse a file and open the result as a PDF graph (requires Graphviz)
gtool parse -g arithmetic.wsn -s E -i input.txt -a graph
```

---

## Usage Examples

### Basic parsing

```swift
import Grammar
import LL_Parsing

// Build a grammar for arithmetic expressions
let grammarText = """
    E  : T Ex
    Ex : '+' T Ex | ε
    T  : F Tx
    Tx : '*' F Tx | ε
    F  : '(' E ')' | n
"""
let grammar = try Grammar(wsn: grammarText, start: "E")
let (prods, _) = grammar.rewriteToStandardForm()
let standardGrammar = Grammar(productions: prods, start: grammar.start, lexicalTokens: [:])

let parser = LLParser(grammar: standardGrammar)

// Check membership
print(parser.recognizes("n + n * n"))  // true
print(parser.recognizes("n + + n"))    // false

// Build and print the parse tree
let tree = try parser.syntaxTree(for: "n + n")
let printable = tree.mapLeafs { range in String("n + n"[range]) }
print(printable)
```

### Traversing the tree

```swift
// Find all terminal-level spans
let spans = tree.leafs  // [Range<String.Index>]

// Compress single-child chains
let compact = tree.compressed()

// Find all uses of '+' in the tree
let addNodes = tree.mapLeafs { range in String("n + n"[range]) }
    .allNodes(where: { $0.name == "Ex" })
```

### Graphviz export

```swift
let dotSource = tree.mapLeafs { range in String(input[range]) }.graphviz
// Write dotSource to a file, then: dot -Tsvg parse.dot -o parse.svg
```

---

## Extending the Parser

### Adding new grammar notations

Implement a new `Grammar(myFormat: String, start: String)` initialiser in the Grammar package. `LLParser` is notation-agnostic—it only consumes the normalised `[Production]` array.

### Error recovery

The current implementation throws on the first error. A synchronisation strategy (e.g. panic-mode recovery) can be added by catching `ParseError` inside `parse(_:)` and advancing the token stream to a synchronisation token before re-entering the loop.

### Parse table materialisation

For grammars that are reused across many inputs, the `predict` function can be replaced with a pre-built `[NonTerminal: [Terminal: Production]]` parse table. This trades initialisation time for faster per-parse lookup.

---

## Dependencies

| Package | Minimum Version | Role |  
|---------|-----------------|------|  
| [Grammar](https://github.com/hakkabon/Grammar) | `main` | Grammar, Production, Symbol, First/Follow |  
| [GrammarTokenizer](https://github.com/hakkabon/GrammarTokenizer) | `main` | Tokenizer, ParserInput |  
| [GrammarDiagram](https://github.com/hakkabon/GrammarDiagram) | `main` | Railroad diagram rendering |  
| [TerminalColors](https://github.com/hakkabon/TerminalColors) | `>= 0.0.1` | ANSI colour output |  
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `>= 1.6.2` | CLI (`gtool`) |  
| [ShellOut](https://github.com/JohnSundell/ShellOut) | `>= 2.0.0` | `dot` / `open` invocation from `gtool` |  

---

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/hakkabon/LL-Parsing.git", branch: "main"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "LL-Parsing", package: "LL-Parsing"),
        ]
    ),
]
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.  

