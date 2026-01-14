const std = @import("std");

/// Built-in JSON grammar in GBNF format
pub const JSON_GRAMMAR =
    \\root ::= object
    \\value ::= object | array | string | number | ("true" | "false" | "null") ws
    \\object ::= "{" ws ( string ":" ws value ("," ws string ":" ws value)* )? "}" ws
    \\array  ::= "[" ws ( value ("," ws value)* )? "]" ws
    \\string ::= "\"" ([^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\"" ws
    \\number ::= ("-"? ([0-9] | [1-9] [0-9]*)) ("." [0-9]+)? ([eE] [-+]? [0-9]+)? ws
    \\ws     ::= ([ \t\n] ws)?
;

/// Built-in JSON array grammar in GBNF format
pub const JSON_ARRAY_GRAMMAR =
    \\root ::= array
    \\value ::= object | array | string | number | ("true" | "false" | "null") ws
    \\object ::= "{" ws ( string ":" ws value ("," ws string ":" ws value)* )? "}" ws
    \\array  ::= "[" ws ( value ("," ws value)* )? "]" ws
    \\string ::= "\"" ([^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\"" ws
    \\number ::= ("-"? ([0-9] | [1-9] [0-9]*)) ("." [0-9]+)? ([eE] [-+]? [0-9]+)? ws
    \\ws     ::= ([ \t\n] ws)?
;

/// Load grammar from file or return built-in grammar
pub fn loadGrammar(allocator: std.mem.Allocator, grammar_file: []const u8) ![:0]const u8 {
    // Check for built-in grammar shortcuts
    if (std.mem.eql(u8, grammar_file, "json")) {
        return try allocator.dupeZ(u8, JSON_GRAMMAR);
    }
    if (std.mem.eql(u8, grammar_file, "json-array")) {
        return try allocator.dupeZ(u8, JSON_ARRAY_GRAMMAR);
    }

    // Load from file
    const file = std.fs.cwd().openFile(grammar_file, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    return try allocator.dupeZ(u8, content);
}

/// Validate GBNF grammar syntax (basic validation)
/// Returns null if valid, or an error message if invalid
pub fn validateGrammar(grammar: []const u8) ?[]const u8 {
    // Check for empty grammar
    if (grammar.len == 0) {
        return "Grammar is empty";
    }

    // Check for root rule
    if (std.mem.indexOf(u8, grammar, "root") == null) {
        return "Grammar must define a 'root' rule";
    }

    // Check for ::= operator
    if (std.mem.indexOf(u8, grammar, "::=") == null) {
        return "Grammar must contain rule definitions (::=)";
    }

    return null;
}
