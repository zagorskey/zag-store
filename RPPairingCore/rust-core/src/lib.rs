use std::{
    ffi::{c_char, CStr, CString},
    net::Ipv4Addr,
    path::PathBuf,
    thread,
};

use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use tokio::net::TcpListener;

pub type ZagRPPairingCallback = extern "C" fn(i32, *const c_char);

fn emit(callback: ZagRPPairingCallback, code: i32, message: impl AsRef<str>) {
    let sanitized = message.as_ref().replace('\0', " ");
    if let Ok(value) = CString::new(sanitized) {
        callback(code, value.as_ptr());
    }
}

#[no_mangle]
pub extern "C" fn zag_rppairing_core_version() -> *mut c_char {
    CString::new("Zag RPPairing Core 0.2")
        .expect("static string")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn zag_rppairing_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// Starts one device-initiated RPPairing session on a dedicated thread.
///
/// Callback codes:
///  1 = starting
///  2 = advertising / waiting for the device
///  3 = device connected
///  4 = PIN generated (message contains the six-digit PIN)
///  5 = paired successfully (message contains device summary)
/// -1 = error
///
/// Returns false only when the supplied C strings are invalid. Runtime failures
/// are delivered asynchronously through the callback.
#[no_mangle]
pub unsafe extern "C" fn zag_rppairing_start(
    host_name: *const c_char,
    output_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else {
        return false;
    };
    if host_name.is_null() || output_path.is_null() {
        return false;
    }

    let Ok(host_name) = CStr::from_ptr(host_name).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(output_path) = CStr::from_ptr(output_path).to_str().map(PathBuf::from) else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 1, "Starting RPPairing host");

        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -1, format!("Runtime failed: {error}"));
                return;
            }
        };

        runtime.block_on(async move {
            if let Err(error) = run_pairing(host_name, output_path, callback).await {
                emit(callback, -1, error);
            }
        });
    });

    true
}

async fn run_pairing(
    host_name: String,
    output_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
        .await
        .map_err(|error| format!("Unable to open pairing listener: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Unable to read pairing listener address: {error}"))?
        .port();

    let mut pairing_file = RpPairingFile::generate(&host_name);
    let host_info = PairableHostInfo::generate(&host_name, "Mac17,7");
    let service_identifier = pairing_file.identifier.clone();

    let txt = host_info.mdns_txt_records(&service_identifier);

    // Hand the already-bound listener's Bonjour metadata to Swift. On iOS we
    // publish with Foundation's NetService so the advertisement participates in
    // the system Local Network privacy path instead of relying on a raw mDNS
    // socket from the Rust process.
    let mut native_bonjour = format!("{port}\n{service_identifier}");
    for (key, value) in &txt {
        native_bonjour.push('\n');
        native_bonjour.push_str(key);
        native_bonjour.push('=');
        native_bonjour.push_str(value);
    }
    emit(callback, 2, native_bonjour);

    let (stream, peer_address) = listener
        .accept()
        .await
        .map_err(|error| format!("Pairing connection failed: {error}"))?;
    emit(callback, 3, format!("Device connected from {peer_address}"));

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let peer = host
        .accept(&mut pairing_file, |pin| async move {
            emit(callback, 4, pin);
        })
        .await
        .map_err(|error| format!("Pairing failed: {error}"))?;

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("Unable to create pairing storage: {error}"))?;
    }
    pairing_file
        .write_to_file(&output_path)
        .await
        .map_err(|error| format!("Unable to save pairing credentials: {error}"))?;

    emit(
        callback,
        5,
        format!(
            "{}|{}|{}",
            peer.name, peer.model, peer.remotepairing_udid
        ),
    );

    Ok(())
}
