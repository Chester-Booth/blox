mod clipboard;
mod daemon;
mod dmenu;
mod hardware;
mod hypr;
mod json;
mod sha256;
mod system;
mod themes;
mod window_state;
mod workspaces;

use std::env;
use std::io;
use std::process;

const PR_SET_PDEATHSIG: i32 = 1;
const SIGTERM: i32 = 15;

unsafe extern "C" {
    fn prctl(option: i32, arg2: usize, arg3: usize, arg4: usize, arg5: usize) -> i32;
    fn getppid() -> i32;
}

/// Arm Linux PR_SET_PDEATHSIG so long-lived daemons exit when Quickshell exits.
pub fn arm_parent_death_signal() {
    let expected = unsafe { getppid() };
    if expected <= 1 {
        process::exit(0);
    }
    unsafe {
        prctl(PR_SET_PDEATHSIG, SIGTERM as usize, 0, 0, 0);
    }
    if unsafe { getppid() } != expected {
        process::exit(0);
    }
}

fn run() -> io::Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let Some(cmd) = args.first().map(String::as_str) else {
        eprintln!("usage: bloxd <dmenu|window-state|bar-daemon|clipboard-watch|clipboard-ingest|status|theme> [args...]");
        process::exit(2);
    };

    match cmd {
        "dmenu" => {
            if !args.iter().any(|a| a == "--no-parent-guard") {
                arm_parent_death_signal();
            }
            dmenu::run()
        }
        "window-state" => {
            if !args.iter().any(|a| a == "--no-parent-guard") {
                arm_parent_death_signal();
            }
            window_state::run()
        }
        "bar-daemon" => {
            if !args.iter().any(|a| a == "--no-parent-guard") {
                arm_parent_death_signal();
            }
            daemon::run()
        }
        "clipboard-watch" => {
            if !args.iter().any(|a| a == "--no-parent-guard") {
                arm_parent_death_signal();
            }
            clipboard::cmd_watch(&args[1..]).map_err(|e| io::Error::new(io::ErrorKind::Other, e))
        }
        "clipboard-ingest" => {
            clipboard::cmd_ingest(&args[1..]).map_err(|e| io::Error::new(io::ErrorKind::Other, e))
        }
        "theme" => {
            let sub = args.get(1).map(String::as_str).unwrap_or("");
            match sub {
                "list" => {
                    let out = themes::cmd_list().map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
                    println!("{out}");
                    Ok(())
                }
                "show" => {
                    let Some(reference) = args.get(2).filter(|s| !s.starts_with("--")) else {
                        eprintln!("usage: bloxd theme show <theme> [--json]");
                        process::exit(2);
                    };
                    let out = themes::cmd_show(reference)
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
                    println!("{out}");
                    Ok(())
                }
                _ => {
                    eprintln!("usage: bloxd theme <list|show> [args...]");
                    process::exit(2);
                }
            }
        }
        "status" => {
            let sub = args.get(1).map(String::as_str).unwrap_or("");
            match sub {
                "system" => {
                    let payload = system::collect_oneshot();
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                "brightness" => {
                    let dev = args.get(2).filter(|s| !s.starts_with("--")).map(String::as_str).unwrap_or("");
                    let probe_ddc = args.iter().any(|a| a == "--probe-ddc");
                    let payload = hardware::brightness_status(dev, probe_ddc);
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                "touchpad" => {
                    let payload = hardware::touchpad_status();
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                "night-light" => {
                    let payload = hardware::night_light_status();
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                "caffeine" => {
                    let payload = hardware::caffeine_status(true);
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                "workspaces" => {
                    let mut resolver = workspaces::DesktopResolver::new();
                    let payload = workspaces::collect_status(&mut resolver);
                    println!("{}", json::encode(&payload));
                    Ok(())
                }
                _ => {
                    eprintln!("usage: bloxd status <system|brightness|touchpad|night-light|caffeine|workspaces>");
                    process::exit(2);
                }
            }
        }
        _ => {
            eprintln!("unknown bloxd command: {cmd}");
            process::exit(2);
        }
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("bloxd: {err}");
        process::exit(1);
    }
}
