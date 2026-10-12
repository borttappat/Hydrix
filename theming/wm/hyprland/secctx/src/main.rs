//! hydrix-secctx: create a Wayland security context (wp_security_context_v1) and hold it open.
//!
//! Binds a Unix socket at `--socket`, hands it to the compositor as a security-context
//! listener with app id `--app-id`, prints `ready` and stays connected. Every client that
//! connects through that socket is sandboxed by the compositor (Hyprland offers it only its
//! unprivileged protocols). The context lives as long as this process: when it exits, the
//! close pipe hangs up and the compositor stops accepting on the socket.
//!
//! Used by waypipe-connect: the sandboxed waypipe client gets only this socket, so even the
//! waypipe process itself never holds an unsandboxed connection to the compositor.

use std::env;
use std::io::Write;
use std::os::fd::AsFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::process::ExitCode;

use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::wl_registry;
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols::wp::security_context::v1::client::{
    wp_security_context_manager_v1::WpSecurityContextManagerV1,
    wp_security_context_v1::WpSecurityContextV1,
};

struct State;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WpSecurityContextManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &WpSecurityContextManagerV1,
        _: <WpSecurityContextManagerV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WpSecurityContextV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &WpSecurityContextV1,
        _: <WpSecurityContextV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

struct Args {
    app_id: String,
    socket: String,
    engine: String,
    instance: Option<String>,
}

fn parse_args() -> Result<Args, String> {
    let mut app_id = None;
    let mut socket = None;
    let mut engine = String::from("hydrix");
    let mut instance = None;
    let mut it = env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut value = || it.next().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--app-id" => app_id = Some(value()?),
            "--socket" => socket = Some(value()?),
            "--engine" => engine = value()?,
            "--instance" => instance = Some(value()?),
            "-h" | "--help" => {
                return Err("usage: hydrix-secctx --app-id ID --socket PATH [--engine NAME] [--instance ID]".into())
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Args {
        app_id: app_id.ok_or("--app-id is required")?,
        socket: socket.ok_or("--socket is required")?,
        engine,
        instance,
    })
}

fn run() -> Result<(), String> {
    let args = parse_args()?;

    let conn = Connection::connect_to_env().map_err(|e| format!("cannot connect to the compositor: {e}"))?;
    let (globals, mut queue) =
        registry_queue_init::<State>(&conn).map_err(|e| format!("registry: {e}"))?;
    let qh = queue.handle();
    let manager: WpSecurityContextManagerV1 = globals
        .bind(&qh, 1..=1, ())
        .map_err(|_| "the compositor offers no wp_security_context_manager_v1")?;

    // A stale socket from a previous run would make bind fail.
    let _ = std::fs::remove_file(&args.socket);
    let listener =
        UnixListener::bind(&args.socket).map_err(|e| format!("cannot bind {}: {e}", args.socket))?;
    std::fs::set_permissions(&args.socket, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("cannot chmod {}: {e}", args.socket))?;

    // The compositor watches close_r; it hangs up when this process (holding close_w) exits.
    let (close_r, close_w) = std::io::pipe().map_err(|e| format!("pipe: {e}"))?;

    let context = manager.create_listener(listener.as_fd(), close_r.as_fd(), &qh, ());
    context.set_sandbox_engine(args.engine);
    context.set_app_id(args.app_id);
    if let Some(instance) = args.instance {
        context.set_instance_id(instance);
    }
    context.commit();
    let mut state = State;
    queue
        .roundtrip(&mut state)
        .map_err(|e| format!("compositor rejected the security context: {e}"))?;

    // The compositor holds its own copies of the listening socket and the read end.
    drop(listener);
    drop(close_r);

    println!("ready");
    let _ = std::io::stdout().flush();

    // Stay connected; when the compositor goes away, so does the context.
    loop {
        if let Err(e) = queue.blocking_dispatch(&mut state) {
            drop(close_w);
            let _ = std::fs::remove_file(&args.socket);
            return Err(format!("compositor connection closed: {e}"));
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("hydrix-secctx: {e}");
            ExitCode::FAILURE
        }
    }
}
