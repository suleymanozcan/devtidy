import Foundation
import Testing
@testable import DevTidyCore

/// Security I-4 / F3-3: the one redactor behind the kill card, the server row and "Ayrıntılar → Komut satırı". Pure: argv in,
/// display text out.
@Suite struct ArgvRedactionTests {
    private let mask = ArgvRedaction.mask

    private func redact(_ tokens: [String]) -> [String] { ArgvRedaction.redact(tokens: tokens) }

    // MARK: Flags

    @Test(arguments: [
        ["--token", "abc"], ["--api-key", "abc"], ["--apiKey", "abc"], ["--password", "abc"], ["--access-token", "abc"],
        ["--client-secret", "abc"], ["--pass", "abc"], ["--auth", "abc"], ["--key", "abc"], ["--cookie", "abc"],
        ["--dsn", "abc"], ["--jwt", "abc"], ["--dbPass", "abc"], ["--db-pass", "abc"], ["-Dpassword", "abc"],
    ] as [[String]])
    func theValueAfterASecretFlagIsHidden(argv: [String]) {
        #expect(redact(["server"] + argv) == ["server", argv[0], mask], "\(argv[0])")
    }

    @Test(arguments: ["--token=abc", "--api-key=abc", "--pass=abc", "--auth=abc", "--key=abc", "--cookie=abc", "--dsn=abc"])
    func theAttachedValueOfASecretFlagIsHidden(token: String) {
        let name = String(token.prefix { $0 != "=" })
        #expect(redact(["server", token, "--port", "3000"]) == ["server", "\(name)=\(mask)", "--port", "3000"], "\(name)")
    }

    @Test(arguments: [
        ["--bypass", "x"], ["--author", "joe"], ["--passWithNoTests", "src/a.test.ts"], ["--keep-alive", "5"],
        ["--keyboard", "us"], ["--port", "3000"], ["--host", "0.0.0.0"], ["--env-file", ".env.local"], ["-p", "3000"],
    ] as [[String]])
    func ordinaryFlagsAreLeftAlone(argv: [String]) {
        #expect(redact(["server"] + argv) == ["server"] + argv, "\(argv[0])")
    }

    @Test func aFlagFollowedByAnotherFlagHidesNothing() {
        #expect(redact(["x", "--token", "--port", "3000"]) == ["x", "--token", "--port", "3000"])
    }

    // MARK: NAME=value

    @Test(arguments: [
        "API_KEY", "GITHUB_TOKEN", "DB_PASSWORD", "MY_SECRET", "PASS", "AUTH", "AWS_CREDENTIALS", "APIKEY", "DB_PASS",
        "NEXTAUTH_SECRET", "sentry_dsn", "Token",
    ])
    func aSecretNamedAssignmentIsHiddenWithoutADash(name: String) {
        #expect(redact(["cross-env", "\(name)=abc123", "next", "dev"]) == ["cross-env", "\(name)=\(mask)", "next", "dev"], "\(name)")
    }

    @Test(arguments: ["NODE_ENV=production", "PORT=3000", "HOST=0.0.0.0", "AUTHOR=me", "KEYBOARD=us", "PASSENGER=1", "TOKENS_URL"])
    func anAssignmentWithAnOrdinaryNameIsLeftAlone(token: String) {
        #expect(redact(["env", token, "node"]) == ["env", token, "node"], "\(token)")
    }

    @Test func aColonAssignmentAfterAnUpperCaseSecretNameIsHidden() {
        #expect(redact(["wrangler", "dev", "--var", "API_TOKEN:abc"]) == ["wrangler", "dev", "--var", "API_TOKEN:\(mask)"])
        // Not an assignment: a host and port, a lower-case script name, a plain variable.
        let kept = ["localhost:3000", "127.0.0.1:5173", "auth:login", "NAME:value", "node:internal/main"]
        #expect(redact(kept) == kept)
    }

    @Test func aSecretAssignmentInsideAFlagValueIsHidden() {
        #expect(redact(["docker", "run", "--env=API_KEY=abc"]) == ["docker", "run", "--env=API_KEY=\(mask)"])
        #expect(redact(["docker", "run", "-e", "API_KEY=abc"]) == ["docker", "run", "-e", "API_KEY=\(mask)"])
    }

    @Test func headerWordsAreHidden() {
        let argv = ["curl", "-H", "Authorization: Bearer abc", "-H", "X-Api-Key: k1", "-H", "Cookie: a=b", "-H", "Accept: text/html"]
        #expect(redact(argv) == ["curl", "-H", "Authorization: \(mask)", "-H", "X-Api-Key: \(mask)", "-H", "Cookie: \(mask)",
                                 "-H", "Accept: text/html"])
        #expect(redact(["echo", "Bearer", "abc123"]) == ["echo", "Bearer", mask])
    }

    // MARK: URLs

    @Test func urlUserinfoIsHiddenAndAnAtSignInThePasswordDoesNotLeakTheRest() {
        #expect(redact(["https://user:hunter2@example.com/path"]) == ["https://\(mask)@example.com/path"])
        #expect(redact(["https://user:p@ss@example.com/path"]) == ["https://\(mask)@example.com/path"])
        #expect(redact(["DATABASE_URL=postgres://u:pw@db:5432/app"]) == ["DATABASE_URL=postgres://\(mask)@db:5432/app"])
        #expect(redact(["--url=http://u:pw@localhost:3000"]) == ["--url=http://\(mask)@localhost:3000"])
        // An `@` after the authority is a path, not userinfo; an scp-style remote has no scheme.
        #expect(redact(["https://registry.npmjs.org/@scope/pkg"]) == ["https://registry.npmjs.org/@scope/pkg"])
        #expect(redact(["git@github.com:org/repo.git"]) == ["git@github.com:org/repo.git"])
    }

    @Test func queryAndFragmentValuesOfSecretNamesAreHidden() {
        let url = "http://localhost:3000/cb?token=abc&page=2&api_key=zzz#access_token=ttt"
        #expect(redact([url]) == ["http://localhost:3000/cb?token=\(mask)&page=2&api_key=\(mask)#access_token=\(mask)"])
        let plain = "http://localhost:3000/list?page=2&sort=asc"
        #expect(redact([plain]) == [plain])
    }

    // MARK: Shell payloads

    @Test func theScriptOfShellDashCIsRedactedWordByWordAndKeepsItsLayout() {
        let script = "vite --token abc123 --port 3000 && FOO=1 API_KEY=zzz node x.js"
        #expect(redact(["/bin/sh", "-c", script])
                == ["/bin/sh", "-c", "vite --token \(mask) --port 3000 && FOO=1 API_KEY=\(mask) node x.js"])
        #expect(redact(["-zsh", "-lc", "A_TOKEN=1 run"]) == ["-zsh", "-lc", "A_TOKEN=\(mask) run"])
        #expect(redact(["bash", "--norc", "-c", "serve --password pw"]) == ["bash", "--norc", "-c", "serve --password \(mask)"])
    }

    @Test func aSecretFlagAtTheEndOfOneCommandDoesNotHideTheNextCommand() {
        #expect(redact(["sh", "-c", "tool --token; echo done"]) == ["sh", "-c", "tool --token; echo done"])
        #expect(redact(["sh", "-c", "tool --token abc; echo done"]) == ["sh", "-c", "tool --token \(mask); echo done"])
    }

    @Test func quotedAndNestedPayloadsAreLookedInto() {
        let nested = "sh -c 'next dev --password=pw -p 3000'"
        #expect(redact(["bash", "-lc", nested]) == ["bash", "-lc", "sh -c 'next dev --password=\(mask) -p 3000'"])
        #expect(redact(["sh", "-c", "curl -H \"Authorization: Bearer abc\" http://x"])
                == ["sh", "-c", "curl -H \"Authorization: \(mask)\" http://x"])
        let threeLevels = "bash -c 'zsh -c \"A_TOKEN=abc\"'"
        #expect(redact(["sh", "-c", threeLevels]) == ["sh", "-c", "bash -c 'zsh -c \"A_TOKEN=\(mask)\"'"])
    }

    @Test func aScriptNestedBeyondTheLimitIsHiddenAsAWhole() {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var script = "run A_TOKEN=abc"
        for _ in 0..<8 { script = "sh -c " + quoted(script) }
        let line = ArgvRedaction.redactedLine(commandLine: script)
        #expect(!line.contains("abc"))
        #expect(line.contains(mask))
    }

    @Test func anArgumentWithWhitespaceThatIsNoScriptIsRedactedWordByWord() {
        #expect(redact(["node", "server.js", "--title", "My App", "--env", "A=1 B_TOKEN=2"])
                == ["node", "server.js", "--title", "My App", "--env", "A=1 B_TOKEN=\(mask)"])
    }

    @Test func aJoinedCommandLineKeepsItsSpacingAndQuoting() {
        let line = "npx  wrangler dev --var \"API_TOKEN:abc\" --port 8787"
        #expect(ArgvRedaction.redactedLine(commandLine: line) == "npx  wrangler dev --var \"API_TOKEN:\(mask)\" --port 8787")
        let plain = "next dev -p 3000 --title 'My App'"
        #expect(ArgvRedaction.redactedLine(commandLine: plain) == plain)
    }

    @Test func argumentsJoinWithOneSpaceAndKeepTheirCount() {
        let argv = ["node", "server.js", "--token", "abc", "--port", "3000"]
        #expect(redact(argv).count == argv.count)
        #expect(ArgvRedaction.redactedLine(arguments: argv) == "node server.js --token \(mask) --port 3000")
    }

    // MARK: Invisible characters

    @Test func invisibleCharactersAreReplacedNotRemoved() {
        let replacement = ArgvRedaction.replacement
        #expect(redact(["x\u{202E}y"]) == ["x\(replacement)y"])
        #expect(redact(["a\u{200B}b", "--name", "x\u{2028}y"]) == ["a\(replacement)b", "--name", "x\(replacement)y"])
        #expect(redact(["x\u{202E}y\nz"]) == ["x\(replacement)y\(replacement)z"])
        #expect(ArgvRedaction.redactedLine(commandLine: "a\tb") == "a\(replacement)b")
        #expect(!ArgvRedaction.redactedLine(arguments: ["\u{202E}evil", "\n"]).unicodeScalars.contains { $0.value == 0x202E || $0 == "\n" })
    }

    // MARK: Idempotence

    @Test func redactingRedactedTextChangesNothing() {
        let samples: [[String]] = [
            ["node", "server.js", "--token", "abc", "--api-key=zzz", "https://u:p@h/x?token=1&a=2", "API_KEY=k", "--var", "A_TOKEN:t"],
            ["sh", "-c", "vite --token abc && FOO=1 API_KEY=zzz node x.js"],
            ["bash", "-lc", "sh -c 'next dev --password=pw -p 3000'"],
            ["curl", "-H", "Authorization: Bearer abc", "echo", "Bearer", "abc"],
            ["x\u{202E}y\nz", "--title", "My App"],
        ]
        for argv in samples {
            let once = redact(argv)
            #expect(redact(once) == once, "\(argv)")
            let line = ArgvRedaction.redactedLine(arguments: argv)
            #expect(ArgvRedaction.redactedLine(commandLine: line) == line, "\(argv)")
        }
    }

    @Test func noSecretValueSurvivesAnyOfTheSamples() {
        let secrets = ["abc123", "zzz999", "hunter2", "ghp_x1", "pw1", "k1"]
        let argv = ["sh", "-c", "run --token abc123 --api-key=zzz999 https://u:hunter2@h/x GITHUB_TOKEN=ghp_x1 --pass pw1 --auth=k1"]
        let line = ArgvRedaction.redactedLine(arguments: argv)
        for secret in secrets { #expect(!line.contains(secret), "\(secret)") }
    }
}
