// cmux desktop shell (Windows/Linux).
//
// Fork of cmux by Manaflow, Inc. (https://github.com/manaflow-ai/cmux). This
// shell only launches the bundled `cmux-tui` server on a loopback WebSocket and
// opens the in-tree web frontend (frontends/web) against it.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use rand::RngCore;
use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

struct Server {
    bin: PathBuf,
    session: String,
    child: Mutex<Option<Child>>,
}

/// Tie the server's lifetime to this process so a hard kill of the app (or a
/// crash) cannot orphan it. Windows: a kill-on-close job object that lives as
/// long as the app. Unix: the kernel's parent-death signal.
#[cfg(windows)]
fn tie_to_parent(child: &Child) {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if job.is_null() {
            return;
        }
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const _,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        AssignProcessToJobObject(job, child.as_raw_handle() as _);
        // Deliberately leak `job`: it must stay open until this process exits.
    }
}

#[cfg(unix)]
fn arm_parent_death_signal(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        command.pre_exec(|| {
            #[cfg(target_os = "linux")]
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            Ok(())
        });
    }
}

fn base_command(bin: &PathBuf) -> Command {
    let mut command = Command::new(bin);
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// Locate the cmux-tui binary: explicit override, the bundled sidecar next to
/// this executable, a dev-tree build, then PATH.
fn find_binary() -> PathBuf {
    let name = if cfg!(windows) { "cmux-tui.exe" } else { "cmux-tui" };
    if let Some(path) = std::env::var_os("CMUX_TUI_BIN") {
        return PathBuf::from(path);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join(name);
            if sibling.exists() {
                return sibling;
            }
        }
    }
    for profile in ["release", "debug"] {
        let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../target")
            .join(profile)
            .join(name);
        if dev.exists() {
            return dev;
        }
    }
    PathBuf::from(name)
}

fn free_loopback_port() -> std::io::Result<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    Ok(listener.local_addr()?.port())
}

fn random_token() -> String {
    let mut bytes = [0_u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn wait_for_port(port: u16, child: &mut Child) -> Result<(), String> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
            return Ok(());
        }
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!("cmux-tui exited early ({status})"));
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    Err("timed out waiting for the cmux-tui WebSocket".into())
}

fn stop_server(server: &Server) {
    // Graceful first: preserves the durable session topology.
    let _ = base_command(&server.bin).args(["--session", &server.session, "server", "stop"]).status();
    if let Some(mut child) = server.child.lock().unwrap().take() {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn main() {
    let app = tauri::Builder::default()
        .setup(|app| {
            let bin = find_binary();
            // A fresh session per launch: a restored session's terminals are not
            // live on Windows (durable terminal hosts are Unix-only), and the
            // job object / parent-death signal already reaps the previous server.
            let session = format!("desktop-{}", std::process::id());

            let port = free_loopback_port()?;
            let token = random_token();
            let mut server_command = base_command(&bin);
            #[cfg(unix)]
            arm_parent_death_signal(&mut server_command);
            let mut child = server_command
                .args([
                    "server",
                    "start",
                    "--session",
                    &session,
                    "--ws",
                    &format!("127.0.0.1:{port}"),
                    "--ws-token",
                    &token,
                ])
                .spawn()
                .map_err(|error| format!("failed to start {}: {error}", bin.display()))?;

            #[cfg(windows)]
            tie_to_parent(&child);
            if let Err(error) = wait_for_port(port, &mut child) {
                let _ = child.kill();
                return Err(error.into());
            }
            // Open the first workspace with a live terminal (ignore failure: the
            // frontend's "+ new workspace" still works).
            let _ = base_command(&bin)
                .args(["--session", &session, "tab", "create", "terminal"])
                .status();
            app.manage(Server { bin, session, child: Mutex::new(Some(child)) });

            // The frontend consumes `?ws=` and the `#token=` fragment, then strips them.
            let url = format!("index.html?ws=ws://127.0.0.1:{port}&autoconnect=1#token={token}");
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App(url.into()))
                .title("cmux")
                .inner_size(1280.0, 800.0)
                .min_inner_size(640.0, 400.0)
                .build()?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building cmux desktop");

    app.run(|handle, event| {
        if let RunEvent::Exit = event {
            if let Some(server) = handle.try_state::<Server>() {
                stop_server(&server);
            }
        }
    });
}
