# LL-Parsing

A Swift library implementing a deterministic, top-down **LL(1)** parser. Given any context-free grammar (loaded from BNF, EBNF, WSN, or `.gen` notation), the parser builds a concrete **parse tree** for valid input sentences, throws a structured `ParseError` on failure via `syntaxTree(for:)`/`parse(_:)`, or — via `parseWithRecovery(_:)` — keeps going past a mistake using panic-mode error recovery, collecting every `SyntaxError` it found along the way instead of stopping at the first one.

Release 0.1.2 owns an executable, evidence-checked LL workload. Run
`swift run -c release ll-microbenchmark [report.json]`; Parser owns the report
envelope, while this repository owns the grammar, input, boundary, and counters.

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
  - [DiagnosticReporter](#diagnosticreporter)
  - [SyntaxTreePrinter & Graphviz](#syntaxtreeprinter--graphviz)
  - [ParserLogger](#parserlogger)
- [LL(1) Algorithm in Depth](#ll1-algorithm-in-depth)
  - [FIRST and FOLLOW Sets](#first-and-follow-sets)
  - [Prediction Function](#prediction-function)
  - [StreamCursor and the two TokenStream front ends](#streamcursor-and-the-two-tokenstream-front-ends)
  - [Parse Stack and Result Stack](#parse-stack-and-result-stack)
  - [Tree Construction](#tree-construction)
- [Error Recovery](#error-recovery)
  - [The algorithm](#the-algorithm)
  - [Using it](#using-it)
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

| Target       | Type       | Purpose                                                                    |
| ------------ | ---------- | -------------------------------------------------------------------------- |
| `LL-Parsing` | Library    | Core parser, syntax-tree data structure, pretty-printer, Graphviz renderer |
| `ll-parse`   | Executable | Command-line interface for loading a grammar and parsing input             |

---

## Architecture

```
LL-Parsing/
├── Sources/
│   ├── LL-Parsing/
│   │   ├── Parser.swift              # Parser protocol + recognizes(_:) helper
│   │   ├── LLParser.swift            # LL(1) algorithm implementation
│   │   ├── ParserLogger.swift        # OSLog category "LL(1)"
│   │   └── ErrorRecovery/
│   │       ├── SyntaxError.swift        # SyntaxError with line/column reporting
│   │       └── DiagnosticReporter.swift # rustc-style pretty-printer for SyntaxError batches
│   └── parse/
│       ├── GrammarTool.swift         # @main ParsableCommand root
│       ├── Parse.swift               # `parse` sub-command
│       └── Definitions.swift         # Notation, Method, Analysis, Source enums
└── Tests/
    └── LL-ParsingTests/
        ├── LL_ParsingTests.swift
        └── ErrorRecoveryTests.swift
```

`SyntaxTree`, `SyntaxTreePrinter`, and `SyntaxTreeGraphviz` are **not** part of this package — they live in the sibling `Parser` package (see below) as shared parse-forest infrastructure other parser packages (CYK, RNGLR, Earley, Earley-Table) also depend on. `LL-Parsing` imports them; it doesn't define them.

The library depends on four sibling packages from the same author:

- **[Grammar](https://github.com/hakkabon/Grammar)** — `Grammar`, `Production`, `Symbol`, `Terminal`, `NonTerminal`, First/Follow computation, standard-form rewriting.
- **[Lexer](https://github.com/hakkabon/Lexer)** — `TokenStream` protocol, plus its two front ends: a DFA lexer bootstrapped from a `GrammarVocabulary`, and GrammarTokenizer's hand-written `Tokenizer` (reached via `TokenizerStream`, used by default — see [LL(1) Algorithm in Depth](#ll1-algorithm-in-depth)).
- **[Parser](https://github.com/hakkabon/Parser)** — `SyntaxTree` (aliased here as `ParseTree`), `SyntaxTreePrinter`, `SyntaxTreeGraphviz`, and the `DeterministicParser`/`GeneralizedParser` protocols shared across this author's parser packages.
- **[GrammarDiagram](https://github.com/hakkabon/GrammarDiagram)** — Railroad-diagram rendering (used by `gtool`).

---

## Core Components

### LLParser

`LLParser` is the heart of the library. It is a concrete `class` that conforms to the shared `DeterministicParser` protocol.

```swift
public class LLParser: DeterministicParser {
    public init(grammar: Grammar)
    public func syntaxTree(for string: String) throws -> ParseTree
    public func parse(_ source: String) throws -> ParseTree
    public func parse<S: TokenStream>(stream: S) throws -> ParseTree

    // Error recovery — see "Error Recovery" below.
    public func parseWithRecovery(_ source: String) -> LLParseResult
    public func parseWithRecovery<S: TokenStream>(stream: S) -> LLParseResult
    public func printDiagnostics(for result: LLParseResult)
}
```

**Initialisation** computes the **FIRST** and **FOLLOW** sets for the entire grammar once via `grammar.firstAndFollow()`, then groups productions by their goal non-terminal into a dictionary for O(1) lookup during parsing. The epsilon and EOF sentinel symbols are also cached at this point.

**`syntaxTree(for:)`** delegates to `parse(_:)`, which tokenizes with the default `TokenizerStream` and hands off to `parse(stream:)`, which runs the main LL(1) loop — see [StreamCursor and the two `TokenStream` front ends](#streamcursor-and-the-two-tokenstream-front-ends). This throw-on-first-error path is unchanged by error recovery.

**`parseWithRecovery(_:)`** runs the same algorithm but returns an immutable `LLParseResult` containing its status, best-effort tree, diagnostics, and recovery edits. It attempts panic-mode recovery after each mistake, possibly surfacing more than one problem from a single call. See [Error Recovery](#error-recovery).

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
public protocol DeterministicParser {
    func syntaxTree(for string: String) throws -> ParseTree
}

public extension DeterministicParser {
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

| Method             | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `mapNodes(_:)`     | Transform every inner node label                                   |
| `mapLeafs(_:)`     | Transform every leaf value (e.g. `Range<String.Index>` → `String`) |
| `filter(_:)`       | Prune subtrees whose root does not satisfy a predicate             |
| `flattened(_:)`    | Inline a node's children into its parent                           |
| `simplified()`     | Collapse single-child nodes (useful for simplifying deep trees)    |
| `allNodes(where:)` | Collect all subtrees whose root satisfies a predicate              |
| `leafs`            | Collect all leaf values in left-to-right order                     |

All transforms respect the `.empty` case and propagate cleanly.

---

### SyntaxError

`SyntaxError` is a compatibility alias for `Parser.ParseDiagnostic`, the diagnostic model shared by deterministic parser packages. `parseWithRecovery` returns these in `LLParseResult.diagnostics`:

```swift
public struct ParseDiagnostic: Error {
    public enum Reason: Equatable {
        case missingToken          // terminal mismatch, recovered by insertion
        case extraToken            // terminal mismatch, recovered by deletion
        case noViableAlternative   // non-terminal prediction failed
        case invalidToken          // lexical error from the underlying TokenStream
        case prematureEndOfInput   // ran out of input with no synchronizing token — unrecoverable
        case emptyNotAllowed       // reserved for callers outside LLParser
        case unknownToken          // reserved for callers outside LLParser
        case unmatchedPattern      // reserved for callers outside LLParser
        case unexpectedToken       // catch-all
    }
    public let range: Range<String.Index>?
    public let reason: Reason
    public let message: String
    public let context: [NonTerminal]   // enclosing non-terminals, outermost first
    public let expected: [Terminal]
    public let found: Terminal?
    public let source: String
    public let line: Int    // 1-based
    public let column: Int  // 1-based
}
```

`line`/`column` are computed once at construction time from `range`'s start (or from the very end of `source`, when `range` is `nil` — e.g. for a `.prematureEndOfInput` error, where there is no token left to point at).

`LLParser`'s throw-on-first-error path (`syntaxTree(for:)`/`parse(_:)`) is unaffected by any of this — it still throws the public `ParseError` enum (`runtimeError`, `tokenError`, `noTokenError`). `ParseError` also conforms to `LocalizedError`, so callers can present `localizedDescription` directly. `SyntaxError` is only ever produced by `parseWithRecovery`.

---

### DiagnosticReporter

`DiagnosticReporter`, now provided by the shared `Parser` package, pretty-prints a batch of `ParseDiagnostic`s in a style modeled on `rustc` — a bold title, the 1-based location, the offending source line, and a squiggly underline beneath the exact token range.

```swift
public struct DiagnosticReporter {
    public init()
    public func report(diagnostics: [SyntaxError])              // prints to stdout
    public func string(for diagnostics: [SyntaxError]) -> String // renders without printing
    public func block(for error: SyntaxError, index: Int) -> String
}
```

Colour is applied via `TerminalColors` and automatically disabled when stdout isn't a TTY or when `NO_COLOR` is set. `LLParser.printDiagnostics(for:)` reports an immutable result's diagnostics.

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
private func predict<S: TokenStream>(A: NonTerminal, cursor: StreamCursor<S>) throws -> Production?
```

`predict` reads its one token of lookahead via `cursor.peek()` — a small `TokenStream`-backed cursor (`StreamCursor`, in `LLParser.swift`) that replaced GrammarTokenizer's `ParserInput` when the [Lexer](https://github.com/hakkabon/Lexer) package's `TokenStream` protocol was adopted. `cursor` is passed by value here since `predict` only peeks — it never advances the caller's position.

For a given non-terminal `A` and the current lookahead terminal, `predict` iterates over all productions `A → rule` and selects the unique one satisfying either:

1. **Token ∈ FIRST(rule)** — the lookahead is in the rule's First set, so this rule can start with it.
2. **ε ∈ FIRST(rule) AND Token ∈ FOLLOW(A)** — the rule is nullable and the token legally follows `A`.

If two productions match (i.e. the grammar is not LL(1) for this non-terminal/lookahead pair), a `Logger.ll.warning` is emitted and the first match is returned. This design surfaces conflicts without aborting, which aids grammar debugging.

---

### `StreamCursor` and the two `TokenStream` front ends

```swift
public func parse(_ source: String) throws -> ParseTree                 // TokenizerStream, by default
public func parse<S: TokenStream>(stream: S) throws -> ParseTree         // any TokenStream
```

`parse(_ string:)` tokenizes with GrammarTokenizer's `Tokenizer` (via `Lexer`'s `TokenizerStream`, configured with this parser's own `symbols` list) and hands the result to `parse(stream:)`. Since LL(1) only ever reads strictly left-to-right with one token of lookahead, `StreamCursor` uses `TokenStream`'s random-access `terminal(at:)` purely as an indexed pull — `peek()`/`advance()` never revisit a past position, so this is a drop-in replacement for the previous `ParserInput`-based cursor, not an algorithmic change.

To drive the parser from a DFA lexer instead — e.g. one bootstrapped from a `GrammarVocabulary` via `LexerBuilder.loadVocabulary(_:)` — build a `LexerTokenStream` and call `parse(stream:)` directly:

```swift
import Lexer

var builder = LexerBuilder()
builder.loadVocabulary(myGrammarVocabulary)
let lexer = try builder.build()
let stream = try LexerTokenStream(source: "n + n", lexer: lexer)

let tree = try parser.parse(stream: stream)
```

---

### Parse Stack and Result Stack

The algorithm uses **two stacks** in parallel:

| Stack         | Type               | Role                                                  |
| ------------- | ------------------ | ----------------------------------------------------- |
| `parseStack`  | `Stack<StackItem>` | Controls the parsing sequence (prediction + matching) |
| `resultStack` | `[ParseTree]`      | Accumulates completed subtrees for tree assembly      |

**Initialization:**

```
parseStack: [ EOF, <start> ]   (EOF at bottom, start symbol on top)
resultStack: []
```

**Main loop — three cases:**

1. **`.reduce(parent: A, childCount: n)`** — Pop `n` entries from `resultStack`, wrap them in `ParseTree.node(A, children:)`, and push back.
2. **`.symbol(.terminal(t))`** — Match `t` against the current token (via `StreamCursor.peek()`, one look-ahead position into whichever `TokenStream` is driving the parse — see [LL(1) Algorithm in Depth](#ll1-algorithm-in-depth)). On success, push `ParseTree.leaf(range)` to `resultStack` and advance the cursor.
3. **`.symbol(.nonTerminal(A))`** — Call `predict(A:cursor:)` to find the applicable production. Push a `.reduce` marker (processed last), then push the production's non-epsilon symbols in **reverse order** (so the first symbol is processed first).

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

## Error Recovery

`syntaxTree(for:)`/`parse(_:)` throw `ParseError` and stop at the very first mistake — fine for validating well-formed input, but not for tooling that wants to report everything wrong with a file in one pass (a linter, an IDE's live diagnostics, a "did you mean" pass over user-submitted grammar text). `parseWithRecovery(_:)` is the same algorithm with **panic-mode recovery** layered on top: on a mistake, it records a `SyntaxError` and tries to resynchronize with the input instead of giving up, so a single call can surface more than one problem.

### The algorithm

This follows the standard predictive-parser recovery scheme (Aho, Sethi & Ullman, *Compilers: Principles, Techniques, and Tools*, §4.4.3):

- **A terminal on top of the parse stack that doesn't match the current token.** Recovery first checks whether the token right *after* the current one would have matched instead — if so, the current token is treated as **extra** and deleted (`SyntaxError.Reason.extraToken`), which recovers cleanly from a single stray token (`a x b` for `S : 'a' 'b'` deletes `x`). Otherwise, the expected token is assumed to have simply been **missing**, and parsing proceeds as though it had been inserted, without consuming input (`SyntaxError.Reason.missingToken`) — the tree gets a `.empty` placeholder in that position so sibling counts stay correct.

- **Input remains after the start symbol is complete.** End-of-input is treated as a real terminal expectation. The throwing parser rejects the first trailing token; the recovering parser reports each remaining token as `SyntaxError.Reason.extraToken`, discards it, and preserves the completed tree.

- **A non-terminal `A` on top of the stack with no production whose FIRST (or FOLLOW, for a nullable production) set contains the lookahead.** Recovery reports `SyntaxError.Reason.noViableAlternative`, then deletes input tokens until one is found in FIRST(A) ∪ FOLLOW(A) — the classic *synchronizing set*:
  
  - Landing in FIRST(A) retries `A`'s prediction with the new lookahead.
  - Landing in FOLLOW(A) — which always implicitly includes end-of-input for the grammar's start symbol, and often does transitively for others — treats `A` as having matched nothing (another `.empty` placeholder) and resumes with whatever follows it.
  - Never finding a synchronizing token before genuine end-of-input is the one case recovery can't paper over: it reports `SyntaxError.Reason.prematureEndOfInput` and stops.

A `.empty` placeholder is used for both of the above, deliberately distinct from the `.node(A, children: [])` a *genuine* epsilon derivation produces — so a recovered tree stays visually and structurally honest about which parts were actually parsed versus assumed.

Diagnostics and concrete insert/delete/skip edits belong to the returned `LLParseResult`. The parser keeps no mutable per-parse diagnostic state, so results from separate calls remain independent.

### Using it

```swift
import Grammar
import LL_Parsing

let grammar = try Grammar(wsn: "S : 'a' 'b' 'c' 'd'", start: "S")
let parser = LLParser(grammar: grammar)

// 'b' and 'd' are missing; 'x' is extra before 'c'; 'y' is trailing input.
let result = parser.parseWithRecovery("a x c y")
if let tree = result.tree {
    print(tree.mapLeafs { String("a x c y"[$0]) })
}
parser.printDiagnostics(for: result)
```

```
Found 4 errors:

[1] Expected "b", but found "x". Assuming "b" was missing.
   --> Line 1:3
       |
     1 | a x c y
       |   ^

[2] Unexpected "x" found. Skipping it.
   --> Line 1:3
       |
     1 | a x c y
       |   ^

[3] Expected "d", but found "y". Assuming "d" was missing.
   --> Line 1:7
       |
     1 | a x c y
       |       ^

[4] Unexpected trailing "y". Skipping it.
   --> Line 1:7
       |
     1 | a x c y
       |       ^
```

Prefer structured values directly? Inspect `result.status`, iterate `result.diagnostics`, or use `result.recoveryEdits`. Each diagnostic carries its own `reason`, `message`, `range`/`line`/`column`, `expected`/`found` terminals, and non-terminal `context`.

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

Panic-mode recovery is implemented — see [Error Recovery](#error-recovery) for `parseWithRecovery(_:)`. Natural directions to take it further:

- **Better insertion/deletion heuristics.** The current terminal-mismatch heuristic only ever looks one token ahead (`peek(ahead: 1)`) to choose between insertion and deletion. A cost-based scheme (try both repairs, prefer whichever consumes fewer tokens before the next successful match) would recover better from multi-token typos at the cost of extra lookahead work.
- **Locale/grammar-specific messages.** `SyntaxError.message` is a fixed English sentence built inside `LLParser`. A grammar could instead supply a message template per non-terminal (e.g. via `lexical { }`-style metadata) for more domain-appropriate wording ("missing closing brace" instead of "expected \"}\"").
- **Grammar-specific messages.** The shared diagnostic structure is parser-independent, while message construction and recovery decisions remain LL-specific. A grammar could supply message templates per non-terminal for more domain-appropriate wording.

### Parse table materialisation

For grammars that are reused across many inputs, the `predict` function can be replaced with a pre-built `[NonTerminal: [Terminal: Production]]` parse table. This trades initialisation time for faster per-parse lookup — with one caveat: `Terminal`'s `==`/`Hashable` is strict structural equality, so a naive `table[A]?[token]` lookup only works directly for plain `.string` terminals. A `.regularExpression`/`.characterRange`/`.stringList` terminal (e.g. one resolved from a `lexical { }` declaration) won't hash to the same bucket as a concrete lexed token, even when `pattern.matches(token)` would be `true` — see `Terminal.matches(_:)` in the Grammar package. A table that needs to support those either keys the inner dictionary by something the lexer already normalises to (e.g. a `TokenClass`/terminal-kind tag rather than the `Terminal` pattern itself), or falls back to a linear `matches(_:)` scan over that non-terminal's alternatives for the pattern-typed cases while keeping the O(1) dictionary path for plain string terminals.

---

## Dependencies

| Package                                                                 | Minimum Version | Role                                                                       |
| ----------------------------------------------------------------------- | --------------- | -------------------------------------------------------------------------- |
| [Grammar](https://github.com/hakkabon/Grammar)                          | `main`          | Grammar, Production, Symbol, First/Follow                                  |
| [Lexer](https://github.com/hakkabon/Lexer)                              | `main`          | TokenStream, TokenizerStream, LexerTokenStream                             |
| [Parser](https://github.com/hakkabon/Parser)                            | `main`          | SyntaxTree (aliased as `ParseTree`), SyntaxTreePrinter, SyntaxTreeGraphviz |
| [GrammarDiagram](https://github.com/hakkabon/GrammarDiagram)            | `main`          | Railroad diagram rendering                                                 |
| [TerminalColors](https://github.com/hakkabon/TerminalColors)            | `>= 0.0.1`      | ANSI colour output (tree printer, `DiagnosticReporter`)                    |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `>= 1.6.2`      | CLI (`gtool`)                                                              |
| [ShellOut](https://github.com/JohnSundell/ShellOut)                     | `>= 2.0.0`      | `dot` / `open` invocation from `gtool`                                     |

---

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/hakkabon/LL-Parsing.git", .upToNextMinor(from: "0.1.2")),
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
