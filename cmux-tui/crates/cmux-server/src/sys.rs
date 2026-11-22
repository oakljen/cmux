//! Thin wrappers over the few OS calls std does not have: user ids, user
//! name, `statvfs`, and fsync of a directory. Unix only; other platforms get
//! `Unsupported` errors (Windows is server.md step 8).

use std::io;
use std::path::Path;

#[cfg(unix)]
mod imp {
    use std::ffi::{CStr, CString};
    use std::io;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    pub fn euid() -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    pub fn uid() -> u32 {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    /// `uid`'s user database entry; its strings point into `buf`.
    fn passwd(uid: u32, buf: &mut [libc::c_char]) -> io::Result<libc::passwd> {
        // SAFETY: zeroed passwd is a valid out-parameter for getpwuid_r.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and buf outlives it.
        let rc =
            unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result) };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        if result.is_null() {
            return Err(io::Error::new(io::ErrorKind::NotFound, format!("no user for uid {uid}")));
        }
        Ok(pwd)
    }

    pub fn user_name(uid: u32) -> io::Result<String> {
        let mut buf = vec![0 as libc::c_char; 4096];
        let pwd = passwd(uid, &mut buf)?;
        if pwd.pw_name.is_null() {
            return Err(io::Error::new(io::ErrorKind::NotFound, format!("no user for uid {uid}")));
        }
        // SAFETY: getpwuid_r returned a NUL-terminated name inside buf.
        let name = unsafe { CStr::from_ptr(pwd.pw_name) };
        Ok(name.to_string_lossy().into_owned())
    }

    pub fn home_dir(uid: u32) -> io::Result<std::path::PathBuf> {
        let mut buf = vec![0 as libc::c_char; 4096];
        let pwd = passwd(uid, &mut buf)?;
        if pwd.pw_dir.is_null() {
            return Err(io::Error::new(io::ErrorKind::NotFound, format!("no home for uid {uid}")));
        }
        // SAFETY: getpwuid_r returned a NUL-terminated path inside buf.
        let dir = unsafe { CStr::from_ptr(pwd.pw_dir) };
        Ok(std::ffi::OsStr::from_bytes(dir.to_bytes()).into())
    }

    pub fn uid_of(name: &str) -> io::Result<Option<u32>> {
        let c = CString::new(name)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "name has NUL"))?;
        let mut buf = vec![0 as libc::c_char; 4096];
        // SAFETY: zeroed passwd is a valid out-parameter for getpwnam_r.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and buf outlives it.
        let rc = unsafe {
            libc::getpwnam_r(c.as_ptr(), &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result)
        };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        Ok((!result.is_null()).then_some(pwd.pw_uid))
    }

    pub fn owner_uid(meta: &std::fs::Metadata) -> u32 {
        use std::os::unix::fs::MetadataExt;
        meta.uid()
    }

    pub fn statvfs(path: &Path) -> io::Result<(u64, u64)> {
        let c = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path has NUL"))?;
        // SAFETY: zeroed statvfs is a valid out-parameter.
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: c is NUL-terminated and st is a valid out-parameter.
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let frsize = st.f_frsize as u64;
        #[allow(clippy::unnecessary_cast)]
        let (avail, blocks) = (st.f_bavail as u64, st.f_blocks as u64);
        Ok((avail.saturating_mul(frsize), blocks.saturating_mul(frsize)))
    }

    pub fn fsync_dir(path: &Path) -> io::Result<()> {
        std::fs::File::open(path)?.sync_all()
    }

    pub fn process_alive(pid: u32) -> bool {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
        if pid <= 0 {
            return false;
        }
        // SAFETY: signal 0 only checks that the process exists.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}

#[cfg(not(unix))]
mod imp {
    use std::io;
    use std::path::Path;

    fn unsupported() -> io::Error {
        io::Error::new(io::ErrorKind::Unsupported, "not supported on this platform yet")
    }

    pub fn euid() -> u32 {
        u32::MAX
    }

    pub fn uid() -> u32 {
        u32::MAX
    }

    pub fn user_name(_uid: u32) -> io::Result<String> {
        std::env::var("USERNAME").map_err(|_| unsupported())
    }

    pub fn uid_of(_name: &str) -> io::Result<Option<u32>> {
        Err(unsupported())
    }

    pub fn home_dir(_uid: u32) -> io::Result<std::path::PathBuf> {
        Err(unsupported())
    }

    pub fn owner_uid(_meta: &std::fs::Metadata) -> u32 {
        u32::MAX
    }

    pub fn statvfs(_path: &Path) -> io::Result<(u64, u64)> {
        Err(unsupported())
    }

    pub fn fsync_dir(_path: &Path) -> io::Result<()> {
        Ok(())
    }

    pub fn process_alive(_pid: u32) -> bool {
        false
    }
}

/// The effective user id (`u32::MAX` where there is none).
pub fn euid() -> u32 {
    imp::euid()
}

/// The real user id.
pub fn uid() -> u32 {
    imp::uid()
}

pub fn is_root() -> bool {
    cfg!(unix) && euid() == 0
}

/// The login name of `uid` from the user database.
pub fn user_name(uid: u32) -> io::Result<String> {
    imp::user_name(uid)
}

/// The home folder of `uid` in the user database: the `HOME` launchd and
/// systemd give that user's services, whatever `HOME` this process has.
pub fn home_dir(uid: u32) -> io::Result<std::path::PathBuf> {
    imp::home_dir(uid)
}

/// The uid of the user `name`, `None` when there is no such user.
pub fn uid_of(name: &str) -> io::Result<Option<u32>> {
    imp::uid_of(name)
}

/// The owner uid of a file (`u32::MAX` where there is none).
pub fn owner_uid(meta: &std::fs::Metadata) -> u32 {
    imp::owner_uid(meta)
}

/// `(free bytes for unprivileged users, total bytes)` of the filesystem
/// holding `path`.
pub fn statvfs(path: &Path) -> io::Result<(u64, u64)> {
    imp::statvfs(path)
}

/// Makes a rename or a new entry in `path` durable.
pub fn fsync_dir(path: &Path) -> io::Result<()> {
    imp::fsync_dir(path)
}

/// True when a process with this pid exists (`kill(pid, 0)`; `EPERM`
/// means it exists under another user).
pub fn process_alive(pid: u32) -> bool {
    imp::process_alive(pid)
}

/// The environment a process of this account started with, as `(name,
/// value)` pairs, byte for byte: Linux `/proc/PID/environ`, macOS
/// `sysctl(KERN_PROCARGS2)`. Only for a process of this account (the
/// kernel refuses others).
///
/// A process with no variable at all is refused: macOS shows no
/// environment for an Apple platform binary, and an empty answer must not
/// read as "every variable unset".
pub fn process_environ(pid: u32) -> io::Result<Vec<(std::ffi::OsString, std::ffi::OsString)>> {
    let env = parse_environ(&environ_block(pid)?);
    if env.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "the system shows no environment for that process",
        ));
    }
    Ok(env)
}

/// `NAME=VALUE` entries separated by NUL bytes, as pairs (an entry with no
/// `=` is skipped).
pub fn parse_environ(block: &[u8]) -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
    block
        .split(|b| *b == 0)
        .filter_map(|entry| {
            let eq = entry.iter().position(|b| *b == b'=')?;
            Some((os_string(&entry[..eq]), os_string(&entry[eq + 1..])))
        })
        .collect()
}

/// The arguments of a process of this account (`argv`, the program name
/// first), byte for byte: Linux `/proc/PID/cmdline`, macOS
/// `sysctl(KERN_PROCARGS2)`.
pub fn process_argv(pid: u32) -> io::Result<Vec<std::ffi::OsString>> {
    let (argv, _) = proc_args(pid)?;
    Ok(argv.iter().map(|a| os_string(a)).collect())
}

#[cfg(unix)]
fn os_string(bytes: &[u8]) -> std::ffi::OsString {
    <std::ffi::OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(bytes).to_owned()
}

#[cfg(not(unix))]
fn os_string(bytes: &[u8]) -> std::ffi::OsString {
    String::from_utf8_lossy(bytes).into_owned().into()
}

fn environ_block(pid: u32) -> io::Result<Vec<u8>> {
    proc_args(pid).map(|(_, env)| env)
}

/// `(argv, environment block)` of a process: each argument without its NUL,
/// and the `NAME=VALUE` entries, each ended by a NUL.
#[cfg(target_os = "linux")]
fn proc_args(pid: u32) -> io::Result<(Vec<Vec<u8>>, Vec<u8>)> {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline"))?;
    let argv = cmdline
        .strip_suffix(&[0])
        .unwrap_or(&cmdline)
        .split(|b| *b == 0)
        .map(<[u8]>::to_vec)
        .collect();
    Ok((argv, std::fs::read(format!("/proc/{pid}/environ"))?))
}

/// `KERN_PROCARGS2`: argc (an int), the executable path, NUL padding, argc
/// argument strings, then the environment strings, ended by an empty one.
#[cfg(target_os = "macos")]
fn proc_args(pid: u32) -> io::Result<(Vec<Vec<u8>>, Vec<u8>)> {
    let pid =
        libc::c_int::try_from(pid).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size: libc::size_t = 0;
    // SAFETY: a valid mib; a null buffer asks for the size.
    let rc = unsafe {
        libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0)
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut buf = vec![0u8; size];
    // SAFETY: buf holds `size` bytes; the kernel writes at most that many.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    buf.truncate(size);
    let bad =
        || io::Error::new(io::ErrorKind::InvalidData, "a KERN_PROCARGS2 block cmux cannot read");
    let argc_len = std::mem::size_of::<libc::c_int>();
    let argc = buf.get(..argc_len).ok_or_else(bad)?;
    let argc = libc::c_int::from_ne_bytes(argc.try_into().map_err(|_| bad())?);
    let mut rest = &buf[argc_len..];
    // The executable path, then its NUL padding.
    let end = rest.iter().position(|b| *b == 0).ok_or_else(bad)?;
    rest = &rest[end..];
    let start = rest.iter().position(|b| *b != 0).ok_or_else(bad)?;
    rest = &rest[start..];
    let mut argv = Vec::new();
    for _ in 0..argc {
        let end = rest.iter().position(|b| *b == 0).ok_or_else(bad)?;
        argv.push(rest[..end].to_vec());
        rest = &rest[end + 1..];
    }
    // The environment ends at the first empty string.
    let mut end = 0;
    while end < rest.len() && rest[end] != 0 {
        end += rest[end..].iter().position(|b| *b == 0).map_or(rest.len() - end, |n| n + 1);
    }
    Ok((argv, rest[..end.min(rest.len())].to_vec()))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn proc_args(_pid: u32) -> io::Result<(Vec<Vec<u8>>, Vec<u8>)> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}
