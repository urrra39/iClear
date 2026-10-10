/// Static shell completions for `iclear`.
public enum Completions {
    static let commands = [
        "status", "why", "explain", "thaw", "freeze", "undo", "mode", "profile", "stats", "advise",
        "quarantine", "habits", "workspace", "simulate", "trace", "config", "doctor", "install",
        "uninstall", "migrate", "stash", "pop", "selftest", "battery", "beachball", "before", "compat", "shield", "hook", "context",
        "leaks", "capacity", "probe", "brake", "blackbox", "bench", "completions",
        "version",
        "help",
    ]
    static let sub: [String: [String]] = [
        "mode": ["observe", "active"], "brake": ["observe", "on", "off", "status", "report", "resume", "quit"],
        "profile": ["work", "batterySaver", "presentation", "dev", "auto"],
        "habits": ["show", "reset", "export"], "quarantine": ["release"], "trace": ["export"],
        "config": ["path", "show", "validate", "allow", "deny", "import", "export"], "thaw": ["--all"],
        "completions": ["zsh", "bash", "fish"], "doctor": ["--report"], "uninstall": ["--purge"], "migrate": ["--dry-run", "--remove-old"],
        "stash": ["list", "show", "drop", "--keep", "--include", "--include-heavy", "--force-unsaved", "--dry-run"],
        "pop": ["--all", "--app"], "battery": ["target"], "selftest": ["--quick", "--no-mic", "--report", "--json"],
        "beachball": ["stats", "log"],
    ]

    public static func script(for shell: String) -> String {
        let all = commands.joined(separator: " ")
        switch shell {
        case "bash":
            let cases = sub.sorted { $0.key < $1.key }.map {
                "    \($0.key)) COMPREPLY=($(compgen -W \"\($0.value.joined(separator: " "))\" -- \"$cur\")) ;;"
            }
            return """
                _iclear() {
                  local cur="${COMP_WORDS[COMP_CWORD]}"
                  if [ "$COMP_CWORD" -eq 1 ]; then COMPREPLY=($(compgen -W "\(all)" -- "$cur")); return; fi
                  case "${COMP_WORDS[1]}" in
                \(cases.joined(separator: "\n"))
                  esac
                }
                complete -F _iclear iclear
                """
        case "fish":
            var l = ["complete -c iclear -f -n '__fish_use_subcommand' -a '\(all)'"]
            for (c, s) in sub.sorted(by: { $0.key < $1.key }) {
                l.append("complete -c iclear -f -n '__fish_seen_subcommand_from \(c)' -a '\(s.joined(separator: " "))'")
            }
            return l.joined(separator: "\n")
        default:
            let cases = sub.sorted { $0.key < $1.key }.map { "    \($0.key)) compadd \($0.value.joined(separator: " ")) ;;" }
            return """
                #compdef iclear
                _iclear() {
                  if (( CURRENT == 2 )); then compadd \(all); return; fi
                  case $words[2] in
                \(cases.joined(separator: "\n"))
                  esac
                }
                _iclear "$@"
                """
        }
    }
}
