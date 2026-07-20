//! Dispatch contract, exercised against the real binary: unknown verb and
//! bare invocation exit 2 with usage; --help exits 0 and lists every verb;
//! argv[0] dispatch through a compat-symlink-shaped name reaches the tool
//! (kubenyx-pki's own parser answers, with its own exit code — proof the
//! flag surface moved intact).

use std::os::unix::fs::symlink;
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_kubenyx");

#[test]
fn unknown_verb_exits_2_with_usage() {
    let out = Command::new(BIN).arg("frobnicate").output().expect("spawn");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("usage: kubenyx"), "stderr: {stderr}");
}

#[test]
fn no_args_exits_2_with_usage() {
    let out = Command::new(BIN).output().expect("spawn");
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("usage: kubenyx"));
}

#[test]
fn help_exits_0_and_lists_verbs() {
    let out = Command::new(BIN).arg("--help").output().expect("spawn");
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    for verb in ["snap", "pki", "ready", "clockstep", "lb", "etcd-mem"] {
        assert!(stdout.contains(verb), "--help must list {verb}: {stdout}");
    }
}

#[test]
fn subcommand_reaches_tool_parser() {
    // kubenyx-snap without a subcommand dies with ITS usage and exit 2 —
    // the tail after the verb lands in the tool's parser unchanged.
    let out = Command::new(BIN).arg("snap").output().expect("spawn");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("usage: kubenyx-snap"), "stderr: {stderr}");
}

#[test]
fn argv0_symlink_dispatches_to_tool() {
    // kubenyx-pki with no --node-name dies with exit 1 and its own error —
    // reached purely via the argv[0] basename, as the nix compat symlinks do.
    let dir = std::env::temp_dir().join(format!("kubenyx-dispatch-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir");
    let link = dir.join("kubenyx-pki");
    let _ = std::fs::remove_file(&link);
    symlink(BIN, &link).expect("symlink");
    let out = Command::new(&link).output().expect("spawn via symlink");
    let _ = std::fs::remove_file(&link);
    let _ = std::fs::remove_dir(&dir);
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("kubenyx-pki: --node-name is required"),
        "stderr: {stderr}"
    );
}
