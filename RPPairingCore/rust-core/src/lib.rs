use std::{
    ffi::{c_char, CStr, CString},
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
    thread,
};

use idevice::remote_pairing::{
    connect_tls_psk_tunnel_native, PairableHost, PairableHostInfo, RemotePairingClient,
    RpPairingFile, RpPairingSocket,
};
use idevice::RsdService;
use idevice::rsd::RsdHandshake;
use idevice::services::lockdown::LockdownClient;
use idevice::services::installation_proxy::InstallationProxyClient;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{timeout, Duration};


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


/// Runs the RPPairing-native Gate 2 probe on a dedicated thread.
///
/// Callback codes:
/// 101 = starting
/// 102 = raw RPPairing service reached
/// 103 = pair-verify in progress
/// 104 = saved RPPairing credentials verified
/// 105 = TLS-PSK CDTunnel established
/// 106 = RSD handshake established
/// 107 = device information read (message is pipe-delimited)
/// 108 = installation_proxy connected over RSD
/// 109 = user-app lookup complete (message: count|zagStoreFound)
/// -2  = device-services probe failure
#[no_mangle]
pub unsafe extern "C" fn zag_gate2_probe(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };
    if device_ip.is_null() || pairing_path.is_null() { return false; }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 101, "Starting RPPairing-native Gate 2 probe");
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -2, format!("Gate 2 runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_gate2_probe(device_ip, pairing_path, callback).await {
                emit(callback, -2, error);
            }
        });
    });
    true
}

async fn run_gate2_probe(
    device_ip: String,
    pairing_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    let ip: IpAddr = device_ip
        .parse()
        .map_err(|error| format!("Invalid LocalDevVPN device address {device_ip}: {error}"))?;

    let mut pairing_file = RpPairingFile::read_from_file(&pairing_path)
        .await
        .map_err(|error| format!("Unable to read saved RPPairing credentials: {error}"))?;

    let stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, 49152)))
        .await
        .map_err(|_| format!("Timed out reaching RPPairing at {device_ip}:49152"))?
        .map_err(|error| format!("Unable to reach RPPairing at {device_ip}:49152: {error}"))?;

    emit(callback, 102, format!("RPPairing reachable at {device_ip}:49152"));
    emit(callback, 103, "Verifying saved RPPairing credentials");

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, "Zag Store");
    rpc.connect(&mut pairing_file, || async { "000000".to_string() })
        .await
        .map_err(|error| format!("RPPairing pair-verify failed: {error}"))?;

    // Persist in case idevice refreshed any pairing metadata.
    pairing_file
        .write_to_file(&pairing_path)
        .await
        .map_err(|error| format!("Unable to persist verified RPPairing credentials: {error}"))?;
    emit(callback, 104, "Saved RPPairing credentials verified");

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|error| format!("RPPairing createListener failed: {error}"))?;
    let tunnel_addr = (ip, tunnel_port);
    let tunnel_stream = timeout(Duration::from_secs(8), TcpStream::connect(tunnel_addr))
        .await
        .map_err(|_| format!("Timed out reaching RPPairing tunnel at {device_ip}:{tunnel_port}"))?
        .map_err(|error| format!("Unable to reach RPPairing tunnel at {device_ip}:{tunnel_port}: {error}"))?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|error| format!("TLS-PSK CDTunnel failed: {error}"))?;

    let client_ip: IpAddr = tunnel.info.client_address.parse()
        .map_err(|error| format!("Invalid tunnel client address: {error}"))?;
    let server_ip: IpAddr = tunnel.info.server_address.parse()
        .map_err(|error| format!("Invalid tunnel server address: {error}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    emit(callback, 105, format!("CDTunnel established; RSD port {rsd_port}"));

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|error| format!("Unable to reach RSD through tunnel: {error}"))?;
    let mut handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|error| format!("RSD handshake failed: {error}"))?;
    emit(callback, 106, format!("RSD established; {} services", handshake.services.len()));

    let mut remote_lockdown = LockdownClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(|error| format!("RSD lockdownd connection failed: {error}"))?;
    let values = remote_lockdown
        .get_value(None, None)
        .await
        .map_err(|error| format!("Reading device information over RSD failed: {error}"))?;

    let dict = values.as_dictionary();
    let device_name = dict.and_then(|d| d.get("DeviceName")).and_then(|v| v.as_string()).unwrap_or("This iPhone");
    let product_type = dict.and_then(|d| d.get("ProductType")).and_then(|v| v.as_string()).unwrap_or("");
    let product_version = dict.and_then(|d| d.get("ProductVersion")).and_then(|v| v.as_string()).unwrap_or("");
    let build_version = dict.and_then(|d| d.get("BuildVersion")).and_then(|v| v.as_string()).unwrap_or("");

    emit(callback, 107, format!("{device_name}|{product_type}|{product_version}|{build_version}"));

    // Gate 3A is deliberately read-only: connect to installation_proxy over the
    // already-proven RSD tunnel and ask it only for the user-app lookup table.
    drop(remote_lockdown);
    let mut installation_proxy = InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(|error| format!("installation_proxy over RSD failed: {error}"))?;
    emit(callback, 108, "installation_proxy connected over RSD");

    let apps = installation_proxy
        .get_apps(Some("User"), None)
        .await
        .map_err(|error| format!("installation_proxy user-app lookup failed: {error}"))?;
    let zag_store_found = apps.contains_key("com.cwd43.gu29");
    emit(callback, 109, format!("{}|{}", apps.len(), zag_store_found));
    Ok(())
}
