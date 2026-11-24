import Foundation

/// Runs command lines against a `CommandContext`.
public final class CommandExecutor {
    public let context: CommandContext
    public var registry: CommandRegistry

    public init(context: CommandContext, registry: CommandRegistry = .standard) {
        self.context = context; self.registry = registry
    }

    /// Executes every command in `line` (separated by `;` or newlines). Returns one result per command
    /// executed; stops after the first failing command. A syntax error yields a single failed result.
    @discardableResult
    public func execute(_ line: String) -> [CommandResult] {
        let cmds: [ParsedCommand]
        do { cmds = try CommandTokenizer.parse(line) }
        catch let e as TokenizerError {
            return [CommandResult(command: line, success: false, messages: [CommandMessage(.error, "syntax error: \(e.description)")])]
        } catch {
            return [CommandResult(command: line, success: false, messages: [CommandMessage(.error, "\(error)")])]
        }
        var results: [CommandResult] = []
        for c in cmds {
            let r = run(c)
            results.append(r)
            if !r.success { break }
        }
        return results
    }

    /// Executes one already-parsed command.
    public func run(_ c: ParsedCommand) -> CommandResult {
        guard let def = registry.lookup(c.name) else {
            return CommandResult(command: c.raw, success: false, messages: [CommandMessage(.error, registry.unknownMessage(c.name))])
        }
        let inv = CommandInvocation(context: context, arguments: c.arguments, registry: registry)
        do {
            let out = try def.handler(inv)
            return CommandResult(command: c.raw, success: true, messages: out.messages, value: out.value)
        } catch let e as CommandError {
            return CommandResult(command: c.raw, success: false, messages: [CommandMessage(.error, e.message)])
        } catch {
            return CommandResult(command: c.raw, success: false, messages: [CommandMessage(.error, error.localizedDescription)])
        }
    }
}
