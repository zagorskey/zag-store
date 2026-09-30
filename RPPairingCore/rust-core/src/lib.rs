use std::{
    ffi::{c_char, CStr, CString},
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
    thread,
};

use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use idevice::{Idevice, IdeviceService, RsdService};
use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::provider::TcpProvider;
use idevice::rsd::RsdHandshake;
use idevice::services::lockdown::LockdownClient;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{timeout, Duration};
use uuid::Uuid;

pub type ZagRPPairingCallback = extern "C" fn(i32, *const c_char);

fn emit(callback: ZagRPPairingCallback, code: i32, message: impl AsRef<str>) {
    let sanitized = message.as_ref().replace('\0', " ");
    if let Ok(value) = CString::new(sanitized) {
        callback(code, value.as_ptr());
    }
}

#[no_mangle]
pub extern "C" fn zag_rppairing_core_version() -> *mut c_char {
    CString::new("Zag RPPairing Core 0.5")
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
    // publish with Foundation's NetService so the advertisement points directly at this listener and participates in
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


/// Runs the first read-only Gate 2 transport probe on a dedicated thread.
///
/// Callback codes:
/// 101 = starting
/// 102 = lockdownd :62078 reached
/// 103 = waiting for / performing classic Pair
/// 104 = classic pairing record saved
/// 105 = CoreDeviceProxy tunnel established
/// 106 = RSD handshake established
/// 107 = device information read (message is pipe-delimited)
/// -2  = Gate 2 failure
#[no_mangle]
pub unsafe extern "C" fn zag_gate2_probe(
    device_ip: *const c_char,
    lockdown_output_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else {
        return false;
    };
    if device_ip.is_null() || lockdown_output_path.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(output_path) = CStr::from_ptr(lockdown_output_path)
        .to_str()
        .map(PathBuf::from)
    else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 101, "Starting Gate 2 device probe");

        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -2, format!("Gate 2 runtime failed: {error}"));
                return;
            }
        };

        runtime.block_on(async move {
            if let Err(error) = run_gate2_probe(device_ip, output_path, callback).await {
                emit(callback, -2, error);
            }
        });
    });

    true
}

async fn run_gate2_probe(
    device_ip: String,
    output_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    let ip: IpAddr = device_ip
        .parse()
        .map_err(|error| format!("Invalid LocalDevVPN device address {device_ip}: {error}"))?;

    let stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, 62078)))
        .await
        .map_err(|_| format!("Timed out reaching lockdownd at {device_ip}:62078"))?
        .map_err(|error| format!("Unable to reach lockdownd at {device_ip}:62078: {error}"))?;

    emit(callback, 102, format!("lockdownd reachable at {device_ip}:62078"));

    let idevice = Idevice::new(Box::new(stream), "Zag Store");
    let mut lockdown = LockdownClient::new(idevice);

    let host_id = Uuid::new_v4().to_string().to_uppercase();
    let system_buid = Uuid::new_v4().to_string().to_uppercase();
    emit(callback, 103, "Requesting classic lockdown pairing — approve Trust if iOS asks");

    let pairing_file = lockdown
        .pair(host_id, system_buid, Some("Zag Store"))
        .await
        .map_err(|error| format!("Classic lockdown pairing failed: {error}"))?;

    let bytes = pairing_file
        .clone()
        .serialize()
        .map_err(|error| format!("Unable to serialize lockdown pairing record: {error}"))?;

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("Unable to create Gate 2 storage: {error}"))?;
    }
    std::fs::write(&output_path, &bytes)
        .map_err(|error| format!("Unable to save lockdown pairing record: {error}"))?;

    emit(
        callback,
        104,
        format!("Classic pairing record saved ({} bytes)", bytes.len()),
    );

    let provider = TcpProvider {
        addr: ip,
        scope_id: None,
        pairing_file,
        label: "Zag Store".to_string(),
    };

    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .map_err(|error| format!("CoreDeviceProxy connection failed: {error}"))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    emit(
        callback,
        105,
        format!("CoreDeviceProxy tunnel established; RSD port {rsd_port}"),
    );

    let adapter = proxy
        .create_software_tunnel()
        .map_err(|error| format!("Unable to create software tunnel: {error}"))?;
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|error| format!("Unable to reach RSD through CoreDeviceProxy: {error}"))?;
    let mut handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|error| format!("RSD handshake failed: {error}"))?;

    emit(
        callback,
        106,
        format!(
            "RSD established; protocol {} with {} services",
            handshake.protocol_version,
            handshake.services.len()
        ),
    );

    let mut remote_lockdown = LockdownClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(|error| format!("RSD lockdownd connection failed: {error}"))?;

    let values = remote_lockdown
        .get_value(None, None)
        .await
        .map_err(|error| format!("Reading device information over RSD failed: {error}"))?;

    let device_name = values
        .as_dictionary()
        .and_then(|d| d.get("DeviceName"))
        .and_then(|v| v.as_string())
        .unwrap_or("This iPhone");
    let product_type = values
        .as_dictionary()
        .and_then(|d| d.get("ProductType"))
        .and_then(|v| v.as_string())
        .unwrap_or("");
    let product_version = values
        .as_dictionary()
        .and_then(|d| d.get("ProductVersion"))
        .and_then(|v| v.as_string())
        .unwrap_or("");
    let build_version = values
        .as_dictionary()
        .and_then(|d| d.get("BuildVersion"))
        .and_then(|v| v.as_string())
        .unwrap_or("");

    emit(
        callback,
        107,
        format!("{device_name}|{product_type}|{product_version}|{build_version}"),
    );

    Ok(())
}
