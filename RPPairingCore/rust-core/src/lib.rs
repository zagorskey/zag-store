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
use idevice::utils::installation::install_package_with_callback_rsd;
use idevice::rsd::RsdHandshake;
use idevice::services::lockdown::LockdownClient;
use idevice::services::installation_proxy::InstallationProxyClient;
use idevice::services::afc::{AfcClient, opcode::AfcFopenMode};
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

    // Preserve the host identity independently from the peer identity.
    let mut pairing_file = if output_path.exists() {
        let bytes = std::fs::read(&output_path)
            .map_err(|error| format!("Unable to read saved pairing credentials: {error}"))?;
        RpPairingFile::from_bytes(&bytes)
            .map_err(|error| format!("Unable to load saved pairing credentials: {error}"))?
    } else {
        RpPairingFile::generate(&host_name)
    };

    let host_identity_path = output_path.with_file_name("rppairing-host-identity.bin");
    let mut host_info = PairableHostInfo::generate(&host_name, "Mac17,7");
    match std::fs::read(&host_identity_path) {
        Ok(saved) if saved.len() == 16 => host_info.alt_irk.copy_from_slice(&saved),
        _ => {
            if let Some(parent) = host_identity_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|error| format!("Unable to create host identity storage: {error}"))?;
            }
            std::fs::write(&host_identity_path, host_info.alt_irk)
                .map_err(|error| format!("Unable to save host identity: {error}"))?;
        }
    }

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
/// 110 = AFC connected over RSD
/// 111 = PublicStaging write complete
/// 112 = PublicStaging read-back verified
/// 113 = diagnostic file deleted
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

    // Gate 3B: prove the staging half of the install pipeline without staging
    // an app. Create one tiny marker in PublicStaging, verify it byte-for-byte,
    // then remove it before returning success.
    drop(installation_proxy);
    let mut afc = AfcClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(|error| format!("AFC over RSD failed: {error}"))?;
    emit(callback, 110, "AFC connected over RSD");

    let staging_path = "/PublicStaging/zag-gate3b-test.txt";
    let marker = b"Zag Store Gate 3B AFC verification";
    {
        let mut file = afc
            .open(staging_path, AfcFopenMode::Wr)
            .await
            .map_err(|error| format!("Opening PublicStaging diagnostic for write failed: {error}"))?;
        file.write_entire(marker)
            .await
            .map_err(|error| format!("Writing PublicStaging diagnostic failed: {error}"))?;
        file.close()
            .await
            .map_err(|error| format!("Closing PublicStaging diagnostic after write failed: {error}"))?;
    }
    emit(callback, 111, format!("Wrote {} bytes to {staging_path}", marker.len()));

    let read_back = {
        let mut file = afc
            .open(staging_path, AfcFopenMode::RdOnly)
            .await
            .map_err(|error| format!("Opening PublicStaging diagnostic for read failed: {error}"))?;
        let bytes = file.read_entire()
            .await
            .map_err(|error| format!("Reading PublicStaging diagnostic failed: {error}"))?;
        file.close()
            .await
            .map_err(|error| format!("Closing PublicStaging diagnostic after read failed: {error}"))?;
        bytes
    };

    if read_back != marker {
        let _ = afc.remove(staging_path).await;
        return Err(format!(
            "PublicStaging verification mismatch: wrote {} bytes, read {} bytes",
            marker.len(),
            read_back.len()
        ));
    }
    emit(callback, 112, format!("Verified {} bytes from {staging_path}", read_back.len()));

    afc.remove(staging_path)
        .await
        .map_err(|error| format!("Removing PublicStaging diagnostic failed: {error}"))?;
    emit(callback, 113, "PublicStaging diagnostic removed");
    Ok(())
}


/// Gate 4: installs one already-signed IPA through the proven on-device
/// RPPairing -> TLS-PSK -> RSD -> AFC/PublicStaging -> installation_proxy path.
///
/// Callback codes:
/// 201 = starting
/// 202 = RPPairing pair-verify complete
/// 203 = TLS-PSK tunnel established
/// 204 = RSD established
/// 205 = package upload/install started
/// 206 = install progress (message is integer percent)
/// 207 = installation complete
/// -4  = Gate 4 failure
#[no_mangle]
pub unsafe extern "C" fn zag_gate4_install(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    ipa_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };
    if device_ip.is_null() || pairing_path.is_null() || ipa_path.is_null() { return false; }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else { return false; };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else { return false; };
    let Ok(ipa_path) = CStr::from_ptr(ipa_path).to_str().map(PathBuf::from) else { return false; };

    thread::spawn(move || {
        emit(callback, 201, "Starting controlled Gate 4 installation");
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -4, format!("Gate 4 runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_gate4_install(device_ip, pairing_path, ipa_path, callback).await {
                emit(callback, -4, error);
            }
        });
    });
    true
}

async fn run_gate4_install(
    device_ip: String,
    pairing_path: PathBuf,
    ipa_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    let ip: IpAddr = device_ip
        .parse()
        .map_err(|error| format!("Invalid LocalDevVPN device address {device_ip}: {error}"))?;

    let metadata = std::fs::metadata(&ipa_path)
        .map_err(|error| format!("Unable to access selected IPA: {error}"))?;
    if !metadata.is_file() || metadata.len() == 0 {
        return Err("Selected IPA is missing or empty".to_string());
    }

    let mut pairing_file = RpPairingFile::read_from_file(&pairing_path)
        .await
        .map_err(|error| format!("Unable to read saved RPPairing credentials: {error}"))?;

    let stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, 49152)))
        .await
        .map_err(|_| format!("Timed out reaching RPPairing at {device_ip}:49152"))?
        .map_err(|error| format!("Unable to reach RPPairing at {device_ip}:49152: {error}"))?;

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, "Zag Store");
    rpc.connect(&mut pairing_file, || async { "000000".to_string() })
        .await
        .map_err(|error| format!("RPPairing pair-verify failed: {error}"))?;
    emit(callback, 202, "Saved RPPairing credentials verified");

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|error| format!("RPPairing createListener failed: {error}"))?;
    let tunnel_stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, tunnel_port)))
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
    emit(callback, 203, format!("CDTunnel established; RSD port {rsd_port}"));

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
    emit(callback, 204, format!("RSD established; {} services", handshake.services.len()));

    emit(callback, 205, format!("Installing {}", ipa_path.file_name().and_then(|x| x.to_str()).unwrap_or("selected IPA")));
    install_package_with_callback_rsd(
        &mut adapter,
        &mut handshake,
        &ipa_path,
        None,
        |(percent, callback)| async move {
            emit(callback, 206, percent.to_string());
        },
        callback,
    )
    .await
    .map_err(|error| format!("Direct installation failed: {error}"))?;

    emit(callback, 207, "Installation complete");
    Ok(())
}


/// Gate 4 uninstall: removes one installed app through the proven
/// RPPairing -> TLS-PSK -> RSD -> installation_proxy path.
///
/// Callback codes:
/// 301 = starting
/// 302 = RPPairing pair-verify complete
/// 303 = TLS-PSK tunnel established
/// 304 = RSD established
/// 305 = installation_proxy connected
/// 306 = uninstall started
/// 307 = uninstall complete
/// -5  = uninstall failure
#[no_mangle]
pub unsafe extern "C" fn zag_gate4_uninstall(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };
    if device_ip.is_null() || pairing_path.is_null() || bundle_id.is_null() { return false; }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else { return false; };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else { return false; };
    let Ok(bundle_id) = CStr::from_ptr(bundle_id).to_str().map(str::to_owned) else { return false; };

    thread::spawn(move || {
        emit(callback, 301, format!("Starting uninstall for {bundle_id}"));
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -5, format!("Uninstall runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_gate4_uninstall(device_ip, pairing_path, bundle_id, callback).await {
                emit(callback, -5, error);
            }
        });
    });
    true
}

async fn run_gate4_uninstall(
    device_ip: String,
    pairing_path: PathBuf,
    bundle_id: String,
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

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, "Zag Store");
    rpc.connect(&mut pairing_file, || async { "000000".to_string() })
        .await
        .map_err(|error| format!("RPPairing pair-verify failed: {error}"))?;
    emit(callback, 302, "Saved RPPairing credentials verified");

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|error| format!("RPPairing createListener failed: {error}"))?;
    let tunnel_stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, tunnel_port)))
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
    emit(callback, 303, format!("CDTunnel established; RSD port {rsd_port}"));

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
    emit(callback, 304, format!("RSD established; {} services", handshake.services.len()));

    let mut installation_proxy = InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(|error| format!("installation_proxy over RSD failed: {error}"))?;
    emit(callback, 305, "installation_proxy connected over RSD");

    emit(callback, 306, format!("Uninstalling {bundle_id}"));
    installation_proxy
        .uninstall(bundle_id.clone(), None)
        .await
        .map_err(|error| format!("Direct uninstall failed for {bundle_id}: {error}"))?;

    emit(callback, 307, format!("Uninstalled {bundle_id}"));
    Ok(())
}
