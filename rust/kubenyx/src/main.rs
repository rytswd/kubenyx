//! kubenyx: multicall binary for the boot-path tools.
//!
//! Dispatch, in order:
//!   1. argv[0] basename — when the binary is reached through one of the
//!      legacy tool names (compat symlinks installed by
//!      pkgs/kubenyx-tools.nix, e.g. `.../bin/kubenyx-pki`), the whole
//!      argv tail goes to that tool. Every module/guest ExecStart keeps
//!      resolving unchanged.
//!   2. first subcommand — `kubenyx snap|pki|ready|clockstep|lb|etcd-mem
//!      <args>`; `kubenyx --help` lists the verbs; anything else is usage
//!      (exit 2).
//!
//! Each tool's parser moved as-is into its library crate, so flag
//! surfaces and exit codes are exactly what the standalone binaries had.

use std::process::exit;

/// verb ↔ legacy argv[0] basename. etcd-mem never carried the kubenyx-
/// prefix, so its verb and legacy name coincide.
const VERBS: &[(&str, &str)] = &[
    ("snap", "kubenyx-snap"),
    ("pki", "kubenyx-pki"),
    ("ready", "kubenyx-ready"),
    ("clockstep", "kubenyx-clockstep"),
    ("lb", "kubenyx-lb"),
    ("etcd-mem", "etcd-mem"),
];

fn verb_for_argv0(basename: &str) -> Option<&'static str> {
    VERBS
        .iter()
        .find(|(_, legacy)| *legacy == basename)
        .map(|(verb, _)| *verb)
}

fn is_verb(word: &str) -> bool {
    VERBS.iter().any(|(verb, _)| *verb == word)
}

fn usage() -> String {
    let verbs: Vec<&str> = VERBS.iter().map(|(verb, _)| *verb).collect();
    format!(
        "usage: kubenyx <verb> [args...]\n\
         verbs: {}\n\
         Also callable through the legacy names ({}) via argv[0].",
        verbs.join(" | "),
        VERBS
            .iter()
            .map(|(_, legacy)| *legacy)
            .collect::<Vec<_>>()
            .join(", "),
    )
}

/// Pure routing (unit-tested): which verb runs, with which argument tail.
#[derive(Debug, PartialEq, Eq)]
enum Route<'a> {
    Run(&'static str, &'a [String]),
    Help,
    Usage,
}

fn route<'a>(argv0: &str, rest: &'a [String]) -> Route<'a> {
    let basename = argv0.rsplit('/').next().unwrap_or(argv0);
    if let Some(verb) = verb_for_argv0(basename) {
        return Route::Run(verb, rest);
    }
    match rest.first().map(String::as_str) {
        Some("--help") | Some("-h") => Route::Help,
        Some(word) if is_verb(word) => {
            // Borrow the verb with 'static lifetime from the table.
            let verb = VERBS.iter().find(|(v, _)| *v == word).unwrap().0;
            Route::Run(verb, &rest[1..])
        }
        _ => Route::Usage,
    }
}

fn run_verb(verb: &str, args: &[String]) -> i32 {
    match verb {
        "snap" => kubenyx_snap::run(args),
        "pki" => kubenyx_pki::run(args),
        "ready" => kubenyx_ready::run(args),
        "clockstep" => kubenyx_clockstep::run(args),
        "etcd-mem" => etcd_mem::run(args),
        #[cfg(feature = "lb")]
        "lb" => kubenyx_lb::run(args),
        #[cfg(not(feature = "lb"))]
        "lb" => {
            eprintln!("kubenyx: built without the lb feature");
            2
        }
        _ => unreachable!("route() only yields table verbs"),
    }
}

fn main() {
    let mut argv = std::env::args();
    let argv0 = argv.next().unwrap_or_default();
    let rest: Vec<String> = argv.collect();
    match route(&argv0, &rest) {
        Route::Run(verb, args) => exit(run_verb(verb, args)),
        Route::Help => {
            println!("{}", usage());
            exit(0);
        }
        Route::Usage => {
            eprintln!("{}", usage());
            exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn argv0_map_covers_every_legacy_name() {
        // Bare basename and full store-path shape both dispatch.
        for (verb, legacy) in VERBS.iter().copied() {
            assert_eq!(verb_for_argv0(legacy), Some(verb));
            let path = format!("/nix/store/eeee-kubenyx-tools-0.1.0/bin/{legacy}");
            let rest = s(&["--flag", "v"]);
            assert_eq!(route(&path, &rest), Route::Run(verb, &rest[..]));
        }
    }

    #[test]
    fn argv0_kubenyx_falls_through_to_subcommands() {
        assert_eq!(verb_for_argv0("kubenyx"), None);
        let rest = s(&["pki", "--node-name", "n1"]);
        assert_eq!(
            route("/nix/store/eeee/bin/kubenyx", &rest),
            Route::Run("pki", &rest[1..])
        );
    }

    #[test]
    fn subcommand_map_covers_every_verb() {
        for (verb, _) in VERBS.iter().copied() {
            let rest = s(&[verb, "--x"]);
            assert_eq!(route("kubenyx", &rest), Route::Run(verb, &rest[1..]));
        }
    }

    #[test]
    fn help_and_usage_routes() {
        assert_eq!(route("kubenyx", &s(&["--help"])), Route::Help);
        assert_eq!(route("kubenyx", &s(&["-h"])), Route::Help);
        assert_eq!(route("kubenyx", &s(&["frobnicate"])), Route::Usage);
        assert_eq!(route("kubenyx", &[]), Route::Usage);
        // Legacy names never existed as verbs; they must not dispatch as
        // subcommands (kubenyx-snap take ≠ kubenyx kubenyx-snap take).
        assert_eq!(route("kubenyx", &s(&["kubenyx-snap"])), Route::Usage);
    }

    #[test]
    fn usage_lists_every_verb() {
        let text = usage();
        for (verb, _) in VERBS.iter().copied() {
            assert!(text.contains(verb), "usage must list {verb}");
        }
    }
}
