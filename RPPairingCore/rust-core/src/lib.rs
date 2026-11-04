use std::{
    ffi::{c_char, CStr, CString},
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
    thread,
};

use idevice::core_device::{AppIconTarget, IconServiceClient};
use idevice::remote_pairing::{
    connect_tls_psk_tunnel_native, PairableHost, PairableHostInfo, RemotePairingClient,
    RpPairingFile, RpPairingSocket,
};
use idevice::rsd::RsdHandshake;
use idevice::services::afc::{opcode::AfcFopenMode, AfcClient};
use idevice::services::installation_proxy::InstallationProxyClient;
use idevice::services::house_arrest::HouseArrestClient;
use idevice::services::lockdown::LockdownClient;
use idevice::utils::installation::{
    install_package_with_callback_rsd,
    upgrade_package_with_callback_rsd,
};
use async_zip::base::read::seek::ZipFileReader;
use futures::AsyncReadExt as _;
use tokio::fs::File;
use tokio::io::{AsyncBufRead, AsyncSeek, BufReader};
use idevice::RsdService;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{timeout, Duration};

pub type ZagRPPairingCallback = extern "C" fn(i32, *const c_char);

async fn zag_ipa_bundle_id<T>(file: &mut T) -> Result<String, String>
where
    T: AsyncBufRead + AsyncSeek + Unpin,
{
    let mut zip_file = ZipFileReader::with_tokio(file)
        .await
        .map_err(|error| format!("Unable to read IPA archive: {error}"))?;

    for index in 0..zip_file.file().entries().len() {
        let mut entry_reader = zip_file
            .reader_with_entry(index)
            .await
            .map_err(|error| format!("Unable to read IPA entry: {error}"))?;

        let entry = entry_reader.entry();

        let inner_path = entry
            .filename()
            .as_str()
            .map_err(|_| "IPA contains an invalid UTF-8 path".to_string())?
            .trim_end_matches('/');

        // Root app Info.plist:
        // Payload/<AppName>.app/Info.plist
        if inner_path.ends_with("Info.plist")
            && inner_path.split('/').count() == 3
        {
            let mut bytes = Vec::new();

            entry_reader
                .read_to_end(&mut bytes)
                .await
                .map_err(|error| format!("Unable to read app Info.plist: {error}"))?;

            let plist = plist::Value::from_reader(std::io::Cursor::new(bytes))
                .map_err(|error| format!("Unable to decode app Info.plist: {error}"))?;

            if let Some(bundle_id) = plist
                .as_dictionary()
                .and_then(|dict| dict.get("CFBundleIdentifier"))
                .and_then(|value| value.as_string())
            {
                return Ok(bundle_id.to_string());
            }
        }
    }

    Err("IPA bundle identifier not found".to_string())
}

fn emit(callback: ZagRPPairingCallback, code: i32, message: impl AsRef<str>) {
    let sanitized = message.as_ref().replace('\0', " ");
    if let Ok(value) = CString::new(sanitized) {
        callback(code, value.as_ptr());
    }
}

#[no_mangle]
pub extern "C" fn zag_rppairing_core_version() -> *mut c_char {
    CString::new("Zag RPPairing Core 0.6")
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
        format!("{}|{}|{}", peer.name, peer.model, peer.remotepairing_udid),
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
    let Some(callback) = callback else {
        return false;
    };
    if device_ip.is_null() || pairing_path.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 101, "Starting RPPairing-native Gate 2 probe");
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
            if let Err(error) = run_gate2_probe(device_ip, pairing_path, callback).await {
                emit(callback, -2, error);
            }
        });
    });
    true
}

/// How a device session authenticates.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum SessionMode {
    /// Installs, inventory and self-update: `RemotePairingClient::connect`,
    /// then the verified credentials are written back. Unchanged.
    Production,
    /// Health check only: the handshake and pair-verify run as separate,
    /// separately reported steps; no pair-setup fallback; pair-verify uses an
    /// in-memory copy of the credentials, and nothing is ever written back.
    Diagnostic,
}

/// An error with its source chain and, for socket errors, the I/O error kind
/// and OS error number. Contains no payloads or key material.
fn error_detail(error: &idevice::IdeviceError) -> String {
    let mut text = format!("{error} [idevice code {}", error.code());
    if let idevice::IdeviceError::Socket(io) = error {
        text.push_str(&format!("; io kind {:?}", io.kind()));
        match io.raw_os_error() {
            Some(code) => text.push_str(&format!("; os error {code}")),
            None => text.push_str("; no os error"),
        }
    }
    text.push(']');
    let mut source = std::error::Error::source(error);
    while let Some(inner) = source {
        text.push_str(&format!(" <- {inner}"));
        source = inner.source();
    }
    text
}

/// The same for a plain I/O error (TCP connect).
fn io_error_detail(error: &std::io::Error) -> String {
    match error.raw_os_error() {
        Some(code) => format!("{error} [io kind {:?}; os error {code}]", error.kind()),
        None => format!("{error} [io kind {:?}; no os error]", error.kind()),
    }
}

async fn with_zag_device_session<F, Fut, T, P>(
    device_ip: &str,
    pairing_path: &PathBuf,
    progress: P,
    operation: F,
) -> Result<T, String>
where
    P: FnMut(u8, String),
    F: FnOnce(idevice::tcp::handle::AdapterHandle, RsdHandshake) -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    with_zag_device_session_mode(device_ip, pairing_path, SessionMode::Production, progress, operation).await
}

async fn with_zag_device_session_mode<F, Fut, T, P>(
    device_ip: &str,
    pairing_path: &PathBuf,
    mode: SessionMode,
    mut progress: P,
    operation: F,
) -> Result<T, String>
where
    P: FnMut(u8, String),
    F: FnOnce(idevice::tcp::handle::AdapterHandle, RsdHandshake) -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let diagnostic = mode == SessionMode::Diagnostic;
    let ip: IpAddr = device_ip
        .parse()
        .map_err(|error| format!("Invalid LocalDevVPN device address {device_ip}: {error}"))?;

    let mut pairing_file = RpPairingFile::read_from_file(pairing_path)
        .await
        .map_err(|error| format!("Unable to read saved RPPairing credentials: {error}"))?;

    let stream = timeout(Duration::from_secs(8), TcpStream::connect((ip, 49152)))
        .await
        .map_err(|_| format!("Timed out reaching RPPairing at {device_ip}:49152"))?
        .map_err(|error| {
            if diagnostic {
                format!("Unable to reach RPPairing at {device_ip}:49152: {}", io_error_detail(&error))
            } else {
                format!("Unable to reach RPPairing at {device_ip}:49152: {error}")
            }
        })?;

    if diagnostic {
        // Socket addresses only: the local address and port the kernel chose.
        let local = stream.local_addr().map(|a| a.to_string()).unwrap_or_else(|_| "unknown".into());
        let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_else(|_| "unknown".into());
        progress(1, format!("RPPairing reachable at {device_ip}:49152 (local {local}, peer {peer})"));
    } else {
        progress(1, format!("RPPairing reachable at {device_ip}:49152"));
    }
    progress(2, "Verifying saved RPPairing credentials".to_string());

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, "Zag Store");

    match mode {
        SessionMode::Production => {
            rpc.connect(&mut pairing_file, || async { "000000".to_string() })
                .await
                .map_err(|error| format!("RPPairing pair-verify failed: {error}"))?;

            pairing_file
                .write_to_file(pairing_path)
                .await
                .map_err(|error| format!("Unable to persist verified RPPairing credentials: {error}"))?;
        }
        SessionMode::Diagnostic => {
            rpc.attempt_pair_verify()
                .await
                .map_err(|error| format!("RPPairing handshake failed: {}", error_detail(&error)))?;
            progress(6, "RPPairing handshake completed".to_string());

            // validate_pairing only reads the credentials but takes them
            // mutably; it gets a copy so the stored file can never change.
            let mut verify_copy = pairing_file.clone();
            rpc.validate_pairing(&mut verify_copy)
                .await
                .map_err(|error| format!("RPPairing pair-verify failed: {}", error_detail(&error)))?;
            drop(verify_copy);
        }
    }

    progress(3, "Saved RPPairing credentials verified".to_string());

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|error| {
            if diagnostic {
                format!("RPPairing createListener failed: {}", error_detail(&error))
            } else {
                format!("RPPairing createListener failed: {error}")
            }
        })?;

    let tunnel_stream = timeout(
        Duration::from_secs(8),
        TcpStream::connect((ip, tunnel_port)),
    )
    .await
    .map_err(|_| format!("Timed out reaching RPPairing tunnel at {device_ip}:{tunnel_port}"))?
    .map_err(|error| {
        if diagnostic {
            format!("Unable to reach RPPairing tunnel at {device_ip}:{tunnel_port}: {}", io_error_detail(&error))
        } else {
            format!("Unable to reach RPPairing tunnel at {device_ip}:{tunnel_port}: {error}")
        }
    })?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|error| {
            if diagnostic {
                format!("TLS-PSK CDTunnel failed: {}", error_detail(&error))
            } else {
                format!("TLS-PSK CDTunnel failed: {error}")
            }
        })?;

    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|error| format!("Invalid tunnel client address: {error}"))?;

    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|error| format!("Invalid tunnel server address: {error}"))?;

    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    progress(4, format!("CDTunnel established; RSD port {rsd_port}"));

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);

    adapter.set_mss(mtu.saturating_sub(60));

    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|error| format!("Unable to reach RSD through tunnel: {error}"))?;

    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|error| {
            if diagnostic {
                format!("RSD handshake failed: {}", error_detail(&error))
            } else {
                format!("RSD handshake failed: {error}")
            }
        })?;

    progress(
        5,
        format!("RSD established; {} services", handshake.services.len()),
    );

    operation(adapter, handshake).await
}

async fn run_gate2_probe(
    device_ip: String,
    pairing_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    with_zag_device_session_mode(
        &device_ip,
        &pairing_path,
        SessionMode::Diagnostic,
        |stage, message| {
            let code = match stage {
                1 => 102,
                2 => 103,
                3 => 104,
                4 => 105,
                5 => 106,
                6 => 114,
                _ => return,
            };
            emit(callback, code, message);
        },
        |mut adapter, mut handshake| async move {
            let mut remote_lockdown = LockdownClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|error| format!("RSD lockdownd connection failed: {error}"))?;

            let values = remote_lockdown
                .get_value(None, None)
                .await
                .map_err(|error| format!("Reading device information over RSD failed: {error}"))?;

            let dict = values.as_dictionary();
            let device_name = dict
                .and_then(|d| d.get("DeviceName"))
                .and_then(|v| v.as_string())
                .unwrap_or("This iPhone");
            let product_type = dict
                .and_then(|d| d.get("ProductType"))
                .and_then(|v| v.as_string())
                .unwrap_or("");
            let product_version = dict
                .and_then(|d| d.get("ProductVersion"))
                .and_then(|v| v.as_string())
                .unwrap_or("");
            let build_version = dict
                .and_then(|d| d.get("BuildVersion"))
                .and_then(|v| v.as_string())
                .unwrap_or("");

            emit(
                callback,
                107,
                format!("{device_name}|{product_type}|{product_version}|{build_version}"),
            );

            drop(remote_lockdown);

            let mut installation_proxy =
                InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                    .await
                    .map_err(|error| format!("installation_proxy over RSD failed: {error}"))?;

            emit(callback, 108, "installation_proxy connected over RSD");

            let apps = installation_proxy
                .get_apps(Some("User"), None)
                .await
                .map_err(|error| format!("installation_proxy user-app lookup failed: {error}"))?;

            let zag_store_found = apps.contains_key("com.cwd43.gu29");
            emit(callback, 109, format!("{}|{}", apps.len(), zag_store_found));

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
                    .map_err(|error| {
                        format!("Opening PublicStaging diagnostic for write failed: {error}")
                    })?;

                file.write_entire(marker)
                    .await
                    .map_err(|error| format!("Writing PublicStaging diagnostic failed: {error}"))?;

                file.close().await.map_err(|error| {
                    format!("Closing PublicStaging diagnostic after write failed: {error}")
                })?;
            }

            emit(
                callback,
                111,
                format!("Wrote {} bytes to {staging_path}", marker.len()),
            );

            let read_back = {
                let mut file =
                    afc.open(staging_path, AfcFopenMode::RdOnly)
                        .await
                        .map_err(|error| {
                            format!("Opening PublicStaging diagnostic for read failed: {error}")
                        })?;

                let bytes = file
                    .read_entire()
                    .await
                    .map_err(|error| format!("Reading PublicStaging diagnostic failed: {error}"))?;

                file.close().await.map_err(|error| {
                    format!("Closing PublicStaging diagnostic after read failed: {error}")
                })?;

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

            emit(
                callback,
                112,
                format!("Verified {} bytes from {staging_path}", read_back.len()),
            );

            afc.remove(staging_path)
                .await
                .map_err(|error| format!("Removing PublicStaging diagnostic failed: {error}"))?;

            emit(callback, 113, "PublicStaging diagnostic removed");

            Ok(())
        },
    )
    .await
}

/// Read-only House Arrest diagnostic for an installed app.
///
/// Callback codes:
/// 601 = starting
/// 602 = installed bundle ID resolved
/// 603 = House Arrest connected
/// 604 = VendDocuments succeeded
/// 605 = Documents listing (TAB-delimited)
/// 606 = complete
/// -8  = failure
#[no_mangle]
pub unsafe extern "C" fn zag_house_arrest_list_documents(
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
        emit(callback, 601, format!("Starting House Arrest probe for {bundle_id}"));
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -8, format!("House Arrest runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            let result = with_zag_device_session(
                &device_ip,
                &pairing_path,
                |_stage, _message| {},
                |mut adapter, mut handshake| async move {
                    let mut installation_proxy =
                        InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                            .await
                            .map_err(|error| format!("installation_proxy over RSD failed: {error}"))?;
                    let apps = installation_proxy
                        .get_apps(Some("User"), None)
                        .await
                        .map_err(|error| format!("installation_proxy user-app lookup failed: {error}"))?;
                    let resolved = if apps.contains_key(&bundle_id) {
                        bundle_id.clone()
                    } else {
                        apps.keys()
                            .find(|id| id.starts_with(&(bundle_id.clone() + ".")))
                            .cloned()
                            .ok_or_else(|| format!("Installed app not found for {bundle_id}"))?
                    };
                    drop(installation_proxy);
                    emit(callback, 602, &resolved);

                    let house_arrest = HouseArrestClient::connect_rsd(&mut adapter, &mut handshake)
                        .await
                        .map_err(|error| format!("House Arrest over RSD failed: {error}"))?;
                    emit(callback, 603, "House Arrest connected over RSD");

                    let mut afc = house_arrest
                        .vend_container(resolved.clone())
                        .await
                        .map_err(|error| format!("VendContainer failed for {resolved}: {error}"))?;
                    emit(callback, 604, format!("VendContainer succeeded for {resolved}"));

                    let preferences_path =
                        "/Library/Preferences/com.SideStore.SideStore.plist";

                    let preferences_bytes = {
                        let mut file = afc
                            .open(preferences_path, AfcFopenMode::RdOnly)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore preferences failed: {error}"
                                )
                            })?;

                        let bytes = file
                            .read_entire()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Reading SideStore preferences failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing SideStore preferences failed: {error}"
                                )
                            })?;

                        bytes
                    };

                    if preferences_bytes.starts_with(b"bplist") {
                        let value = plist::Value::from_reader(
                            std::io::Cursor::new(&preferences_bytes)
                        )
                        .map_err(|error| {
                            format!(
                                "Decoding SideStore binary plist failed: {error}"
                            )
                        })?;

                        let dictionary = value
                            .as_dictionary()
                            .ok_or_else(|| {
                                "SideStore preferences plist root is not a dictionary".to_string()
                            })?;

                        let active = match dictionary.get("activePairingProtocol") {
                            Some(plist::Value::String(value)) => value.clone(),
                            Some(value) => format!("<unexpected: {value:?}>"),
                            None => "<missing>".to_string(),
                        };

                        let reset = match dictionary.get("isPairingReset") {
                            Some(plist::Value::Boolean(value)) => value.to_string(),
                            Some(value) => format!("<unexpected: {value:?}>"),
                            None => "<missing>".to_string(),
                        };

                        let preferred = match dictionary.get("preferredPairingProtocol") {
                            Some(plist::Value::String(value)) => value.clone(),
                            Some(value) => format!("<unexpected: {value:?}>"),
                            None => "<missing>".to_string(),
                        };

                        let pairing_path =
                            "/Documents/PairingFile_RemoteRP.plist";

                        let pairing_status = match afc
                            .open(pairing_path, AfcFopenMode::RdOnly)
                            .await
                        {
                            Ok(mut file) => {
                                match file.read_entire().await {
                                    Ok(bytes) => {
                                        let close_result = file.close().await;

                                        match close_result {
                                            Ok(()) => format!(
                                                "PRESENT — {} bytes",
                                                bytes.len()
                                            ),
                                            Err(error) => format!(
                                                "PRESENT — {} bytes — close failed: {error}",
                                                bytes.len()
                                            ),
                                        }
                                    }
                                    Err(error) => {
                                        let _ = file.close().await;
                                        format!("PRESENT but read failed: {error}")
                                    }
                                }
                            }
                            Err(error) => format!("MISSING/UNREADABLE: {error}"),
                        };

                        let mut keys: Vec<String> =
                            dictionary.keys().cloned().collect();
                        keys.sort();

                        emit(
                            callback,
                            605,
                            format!(
                                "SideStore pairing state\n\nactivePairingProtocol = {active}\nisPairingReset = {reset}\npreferredPairingProtocol = {preferred}\nPairingFile_RemoteRP.plist = {pairing_status}\n\nPreferences: {} keys\n{}",
                                keys.len(),
                                keys.join("\n")
                            ),
                        );
                    } else {
                        emit(
                            callback,
                            605,
                            format!(
                                "Unexpected non-binary plist — {} bytes",
                                preferences_bytes.len()
                            ),
                        );
                    }
                    Ok(())
                },
            ).await;
            if let Err(error) = result { emit(callback, -8, error); }
        });
    });
    true
}


/// Copies Zag Store's saved pairing record into SideStore's shared Documents folder.
///
/// Destination is intentionally fixed:
/// /Documents/PairingFile_RemoteRP.plist
///
/// Callback codes:
/// 611 = starting
/// 612 = installed bundle ID resolved
/// 613 = VendDocuments succeeded
/// 614 = pairing file written
/// 615 = byte-for-byte verification succeeded
/// 616 = complete
/// -9  = failure
#[no_mangle]
pub unsafe extern "C" fn zag_house_arrest_install_pairing_file(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };

    if device_ip.is_null() || pairing_path.is_null() || bundle_id.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };

    let Ok(pairing_path) =
        CStr::from_ptr(pairing_path).to_str().map(PathBuf::from)
    else {
        return false;
    };

    let Ok(bundle_id) = CStr::from_ptr(bundle_id).to_str().map(str::to_owned) else {
        return false;
    };

    thread::spawn(move || {
        emit(
            callback,
            611,
            format!("Preparing pairing file transfer for {bundle_id}"),
        );

        let pairing_bytes = match std::fs::read(&pairing_path) {
            Ok(bytes) if !bytes.is_empty() => bytes,
            Ok(_) => {
                emit(callback, -9, "Saved pairing file is empty");
                return;
            }
            Err(error) => {
                emit(
                    callback,
                    -9,
                    format!("Reading saved pairing file failed: {error}"),
                );
                return;
            }
        };

        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(
                    callback,
                    -9,
                    format!("House Arrest runtime failed: {error}"),
                );
                return;
            }
        };

        runtime.block_on(async move {
            let result = with_zag_device_session(
                &device_ip,
                &pairing_path,
                |_stage, _message| {},
                |mut adapter, mut handshake| async move {
                    let mut installation_proxy =
                        InstallationProxyClient::connect_rsd(
                            &mut adapter,
                            &mut handshake,
                        )
                        .await
                        .map_err(|error| {
                            format!(
                                "installation_proxy over RSD failed: {error}"
                            )
                        })?;

                    let apps = installation_proxy
                        .get_apps(Some("User"), None)
                        .await
                        .map_err(|error| {
                            format!(
                                "installation_proxy user-app lookup failed: {error}"
                            )
                        })?;

                    let resolved = if apps.contains_key(&bundle_id) {
                        bundle_id.clone()
                    } else {
                        apps.keys()
                            .find(|id| {
                                id.starts_with(
                                    &(bundle_id.clone() + ".")
                                )
                            })
                            .cloned()
                            .ok_or_else(|| {
                                format!(
                                    "Installed app not found for {bundle_id}"
                                )
                            })?
                    };

                    drop(installation_proxy);

                    emit(callback, 612, &resolved);

                    let house_arrest =
                        HouseArrestClient::connect_rsd(
                            &mut adapter,
                            &mut handshake,
                        )
                        .await
                        .map_err(|error| {
                            format!(
                                "House Arrest over RSD failed: {error}"
                            )
                        })?;

                    let mut afc = house_arrest
                        .vend_documents(resolved.clone())
                        .await
                        .map_err(|error| {
                            format!(
                                "VendDocuments failed for {resolved}: {error}"
                            )
                        })?;

                    emit(
                        callback,
                        613,
                        format!(
                            "VendDocuments succeeded for {resolved}"
                        ),
                    );

                    let destination =
                        "/Documents/PairingFile_RemoteRP.plist";

                    {
                        let mut file = afc
                            .open(destination, AfcFopenMode::Wr)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore pairing file for write failed: {error}"
                                )
                            })?;

                        file.write_entire(&pairing_bytes)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Writing SideStore pairing file failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing SideStore pairing file failed: {error}"
                                )
                            })?;
                    }

                    emit(
                        callback,
                        614,
                        format!(
                            "Wrote {} bytes to {destination}",
                            pairing_bytes.len()
                        ),
                    );

                    let read_back = {
                        let mut file = afc
                            .open(destination, AfcFopenMode::RdOnly)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore pairing file for verification failed: {error}"
                                )
                            })?;

                        let bytes = file
                            .read_entire()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Reading SideStore pairing file for verification failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing verified SideStore pairing file failed: {error}"
                                )
                            })?;

                        bytes
                    };

                    if read_back != pairing_bytes {
                        return Err(format!(
                            "Pairing file verification mismatch: wrote {} bytes, read {} bytes",
                            pairing_bytes.len(),
                            read_back.len()
                        ));
                    }

                    emit(
                        callback,
                        615,
                        format!(
                            "Verified {} bytes byte-for-byte",
                            read_back.len()
                        ),
                    );

                    // Configure SideStore exactly as its normal RPPairing
                    // import path does: make RPPairing active and clear the
                    // pairing-reset flag. Preserve every unrelated preference.
                    drop(afc);

                    let house_arrest =
                        HouseArrestClient::connect_rsd(
                            &mut adapter,
                            &mut handshake,
                        )
                        .await
                        .map_err(|error| {
                            format!(
                                "House Arrest reconnect for SideStore preferences failed: {error}"
                            )
                        })?;

                    let mut container_afc = house_arrest
                        .vend_container(resolved.clone())
                        .await
                        .map_err(|error| {
                            format!(
                                "VendContainer failed for {resolved}: {error}"
                            )
                        })?;

                    let preferences_path =
                        "/Library/Preferences/com.SideStore.SideStore.plist";

                    let original_preferences = {
                        let mut file = container_afc
                            .open(preferences_path, AfcFopenMode::RdOnly)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore preferences failed: {error}"
                                )
                            })?;

                        let bytes = file
                            .read_entire()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Reading SideStore preferences failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing SideStore preferences failed: {error}"
                                )
                            })?;

                        bytes
                    };

                    let mut preferences = plist::Value::from_reader(
                        std::io::Cursor::new(&original_preferences)
                    )
                    .map_err(|error| {
                        format!(
                            "Decoding SideStore preferences failed: {error}"
                        )
                    })?;

                    {
                        let dictionary = preferences
                            .as_dictionary_mut()
                            .ok_or_else(|| {
                                "SideStore preferences plist root is not a dictionary".to_string()
                            })?;

                        dictionary.insert(
                            "activePairingProtocol".to_string(),
                            plist::Value::String("rppairing".to_string()),
                        );

                        dictionary.insert(
                            "isPairingReset".to_string(),
                            plist::Value::Boolean(false),
                        );
                    }

                    let mut updated_preferences = Vec::new();

                    preferences
                        .to_writer_binary(&mut updated_preferences)
                        .map_err(|error| {
                            format!(
                                "Encoding SideStore preferences failed: {error}"
                            )
                        })?;

                    {
                        let mut file = container_afc
                            .open(preferences_path, AfcFopenMode::Wr)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore preferences for write failed: {error}"
                                )
                            })?;

                        file.write_entire(&updated_preferences)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Writing SideStore preferences failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing updated SideStore preferences failed: {error}"
                                )
                            })?;
                    }

                    let verified_preferences = {
                        let mut file = container_afc
                            .open(preferences_path, AfcFopenMode::RdOnly)
                            .await
                            .map_err(|error| {
                                format!(
                                    "Opening SideStore preferences for verification failed: {error}"
                                )
                            })?;

                        let bytes = file
                            .read_entire()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Reading SideStore preferences for verification failed: {error}"
                                )
                            })?;

                        file.close()
                            .await
                            .map_err(|error| {
                                format!(
                                    "Closing verified SideStore preferences failed: {error}"
                                )
                            })?;

                        bytes
                    };

                    let verified = plist::Value::from_reader(
                        std::io::Cursor::new(&verified_preferences)
                    )
                    .map_err(|error| {
                        format!(
                            "Decoding verified SideStore preferences failed: {error}"
                        )
                    })?;

                    let verified_dictionary = verified
                        .as_dictionary()
                        .ok_or_else(|| {
                            "Verified SideStore preferences root is not a dictionary".to_string()
                        })?;

                    match verified_dictionary.get("activePairingProtocol") {
                        Some(plist::Value::String(value))
                            if value == "rppairing" => {}
                        other => {
                            return Err(format!(
                                "SideStore activePairingProtocol verification failed: {other:?}"
                            ));
                        }
                    }

                    match verified_dictionary.get("isPairingReset") {
                        Some(plist::Value::Boolean(false)) => {}
                        other => {
                            return Err(format!(
                                "SideStore isPairingReset verification failed: {other:?}"
                            ));
                        }
                    }

                    emit(
                        callback,
                        616,
                        format!(
                            "SideStore configured: pairing file verified; activePairingProtocol=rppairing; isPairingReset=false; preserved {} preference bytes",
                            original_preferences.len()
                        ),
                    );

                    Ok(())
                },
            )
            .await;

            if let Err(error) = result {
                emit(callback, -9, error);
            }
        });
    });

    true
}

#[no_mangle]
pub unsafe extern "C" fn zag_installed_apps(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };
    if device_ip.is_null() || pairing_path.is_null() { return false; }
    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else { return false; };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else { return false; };

    thread::spawn(move || {
        emit(callback, 401, "Refreshing installed apps");
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -6, format!("Installed-app inventory runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_installed_apps(device_ip, pairing_path, callback).await {
                emit(callback, -6, error);
            }
        });
    });
    true
}

async fn run_installed_apps(
    device_ip: String,
    pairing_path: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    with_zag_device_session(
        &device_ip,
        &pairing_path,
        |_stage, _message| {},
        |mut adapter, mut handshake| async move {
            let mut installation_proxy =
                InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                    .await
                    .map_err(|error| format!("installation_proxy over RSD failed: {error}"))?;
            let apps = installation_proxy
                .get_apps(Some("User"), None)
                .await
                .map_err(|error| format!("installation_proxy user-app lookup failed: {error}"))?;
            let count = apps.len();
            let mut emitted_debug_keys = false;
            for (bundle_id, metadata) in &apps {
                let dictionary = metadata.as_dictionary();

                if !emitted_debug_keys {
                    let keys = dictionary
                        .map(|values| values.keys().cloned().collect::<Vec<_>>().join(", "))
                        .unwrap_or_else(|| "<not a dictionary>".to_string());
                    emit(callback, 404, format!("{bundle_id}: {keys}"));
                    emitted_debug_keys = true;
                }
                let version = dictionary
                    .and_then(|values| values.get("CFBundleShortVersionString"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let build = dictionary
                    .and_then(|values| values.get("CFBundleVersion"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let name = dictionary
                    .and_then(|values| values.get("CFBundleDisplayName")
                        .or_else(|| values.get("CFBundleName")))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let executable = dictionary
                    .and_then(|values| values.get("CFBundleExecutable"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let minimum_os = dictionary
                    .and_then(|values| values.get("MinimumOSVersion"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let application_type = dictionary
                    .and_then(|values| values.get("ApplicationType"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");
                let signer_identity = dictionary
                    .and_then(|values| values.get("SignerIdentity"))
                    .and_then(|value| value.as_string())
                    .unwrap_or("");

                // 402 payload:
                // bundleID<TAB>shortVersion<TAB>buildVersion<TAB>name<TAB>
                // executable<TAB>minimumOS<TAB>applicationType<TAB>signerIdentity.
                //
                // Keep the callback ABI unchanged. The Swift receiver accepts
                // missing trailing fields so older Rust cores remain harmless.
                emit(
                    callback,
                    402,
                    format!(
                        "{bundle_id}\t{version}\t{build}\t{name}\t{executable}\t{minimum_os}\t{application_type}\t{signer_identity}"
                    ),
                );
            }
            emit(callback, 403, count.to_string());
            Ok(())
        },
    )
    .await
}

/// Fetches rendered icons for installed apps through CoreDevice iconservice.
///
/// bundle_ids is a TAB-delimited list. Each successfully fetched icon is written
/// as <bundle-id>.png under output_dir.
///
/// Callback codes:
/// 501 = starting
/// 502 = icon written (message: bundleID<TAB>absolutePath)
/// 503 = complete (message: success count)
/// -7  = icon refresh failure
#[no_mangle]
pub unsafe extern "C" fn zag_installed_app_icons(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    bundle_ids: *const c_char,
    output_dir: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else { return false; };
    if device_ip.is_null() || pairing_path.is_null() || bundle_ids.is_null() || output_dir.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else { return false; };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else { return false; };
    let Ok(bundle_ids) = CStr::from_ptr(bundle_ids).to_str().map(str::to_owned) else { return false; };
    let Ok(output_dir) = CStr::from_ptr(output_dir).to_str().map(PathBuf::from) else { return false; };

    thread::spawn(move || {
        emit(callback, 501, "Refreshing installed app icons");
        let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -7, format!("Installed-app icon runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_installed_app_icons(
                device_ip,
                pairing_path,
                bundle_ids,
                output_dir,
                callback,
            ).await {
                emit(callback, -7, error);
            }
        });
    });

    true
}

async fn run_installed_app_icons(
    device_ip: String,
    pairing_path: PathBuf,
    bundle_ids: String,
    output_dir: PathBuf,
    callback: ZagRPPairingCallback,
) -> Result<(), String> {
    let requested = bundle_ids
        .split('\t')
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>();

    std::fs::create_dir_all(&output_dir)
        .map_err(|error| format!("Unable to create installed icon cache: {error}"))?;

    with_zag_device_session(
        &device_ip,
        &pairing_path,
        |_stage, _message| {},
        |mut adapter, mut handshake| async move {
            let mut icon_service =
                IconServiceClient::connect_rsd(&mut adapter, &mut handshake)
                    .await
                    .map_err(|error| format!("CoreDevice iconservice over RSD failed: {error}"))?;

            let mut success_count = 0usize;
            for bundle_id in requested {
                let icon = match icon_service
                    .fetch_icon(
                        AppIconTarget::BundleIdentifier(bundle_id.clone()),
                        62.0,
                        62.0,
                        3.0,
                        false,
                    )
                    .await
                {
                    Ok(icon) if !icon.is_placeholder => icon,
                    Ok(_) => continue,
                    Err(_) => continue,
                };

                let path = output_dir.join(format!("{bundle_id}.png"));
                let png: Vec<u8> = icon.png_data.into();
                if std::fs::write(&path, png).is_ok() {
                    success_count += 1;
                    emit(
                        callback,
                        502,
                        format!("{}\t{}", bundle_id, path.to_string_lossy()),
                    );
                }
            }

            emit(callback, 503, success_count.to_string());
            Ok(())
        },
    )
    .await
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
/// 206 = installation_proxy progress (message is integer percent)
/// 207 = installation complete
/// 208 = signed IPA staging progress (actual transferred byte percentage)
/// 209 = signed IPA fully staged via AFC
/// 210 = Upgrade request transmitted (NOT a completion acknowledgment)
/// 211 = real installation_proxy Status (not a completion guarantee)
/// -4  = Gate 4 failure
#[no_mangle]
pub unsafe extern "C" fn zag_gate4_install(
    device_ip: *const c_char,
    pairing_path: *const c_char,
    ipa_path: *const c_char,
    callback: Option<ZagRPPairingCallback>,
) -> bool {
    let Some(callback) = callback else {
        return false;
    };
    if device_ip.is_null() || pairing_path.is_null() || ipa_path.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else {
        return false;
    };
    let Ok(ipa_path) = CStr::from_ptr(ipa_path).to_str().map(PathBuf::from) else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 201, "Starting controlled Gate 4 installation");
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -4, format!("Gate 4 runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) = run_gate4_install(device_ip, pairing_path, ipa_path, callback).await
            {
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
    let metadata = std::fs::metadata(&ipa_path)
        .map_err(|error| format!("Unable to access selected IPA: {error}"))?;
    if !metadata.is_file() || metadata.len() == 0 {
        return Err("Selected IPA is missing or empty".to_string());
    }

    with_zag_device_session(
        &device_ip,
        &pairing_path,
        |stage, message| {
            let code = match stage {
                3 => 202,
                4 => 203,
                5 => 204,
                _ => return,
            };
            emit(callback, code, message);
        },
        |mut adapter, mut handshake| async move {
            // Read the incoming IPA's real bundle identifier so we can
            // distinguish a fresh install from replacement of an existing app.
            let ipa_file = File::open(&ipa_path)
                .await
                .map_err(|error| format!("Unable to open selected IPA: {error}"))?;
            let mut ipa_reader = BufReader::new(ipa_file);
            let bundle_id = zag_ipa_bundle_id(&mut ipa_reader).await?;

            // Ask installation_proxy whether that exact bundle ID already
            // exists on the device.
            let mut installation_proxy =
                InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                    .await
                    .map_err(|error| {
                        format!("installation_proxy over RSD failed: {error}")
                    })?;

            let apps = installation_proxy
                .get_apps(Some("User"), None)
                .await
                .map_err(|error| {
                    format!("installation_proxy user-app lookup failed: {error}")
                })?;

            let is_upgrade = apps.contains_key(&bundle_id);
            drop(installation_proxy);

            // Fail closed for Zag Store itself. A self-update must never
            // silently fall back to a fresh installation when the existing
            // app is absent from installation_proxy's user-app inventory.
            if bundle_id == "com.cwd43.gu29" && !is_upgrade {
                return Err(
                    "Zag Store self-update refused: installed app not found; fresh installation is forbidden"
                        .to_string(),
                );
            }

            emit(
                callback,
                205,
                format!(
                    "{} {}",
                    if is_upgrade { "Upgrading" } else { "Installing" },
                    bundle_id
                ),
            );

            if bundle_id == "com.cwd43.gu29" && is_upgrade {
                // Only the verified self-update uses streamed AFC staging.
                // Other installations retain the original proven helper path.
                let total = std::fs::metadata(&ipa_path)
                    .map_err(|error| format!("Self-update IPA metadata failed: {error}"))?
                    .len();
                if total == 0 {
                    return Err("Self-update IPA is empty".to_string());
                }
                let mut afc = AfcClient::connect_rsd(&mut adapter, &mut handshake)
                    .await
                    .map_err(|error| format!("Self-update AFC connection failed: {error}"))?;
                if afc.get_file_info("PublicStaging").await.is_err() {
                    afc.mk_dir("PublicStaging")
                        .await
                        .map_err(|error| format!("Cannot create PublicStaging: {error}"))?;
                }

                let mut input = File::open(&ipa_path)
                    .await
                    .map_err(|error| format!("Cannot open signed IPA for staging: {error}"))?;
                let mut output = afc
                    .open("PublicStaging/idevice.ipa", AfcFopenMode::WrOnly)
                    .await
                    .map_err(|error| format!("Cannot open staged IPA on device: {error}"))?;
                let mut buffer = vec![0u8; 128 * 1024];
                let mut written = 0u64;
                let mut previous_percent = 0u64;
                loop {
                    let count = tokio::io::AsyncReadExt::read(&mut input, &mut buffer)
                        .await
                        .map_err(|error| format!("Reading signed IPA failed: {error}"))?;
                    if count == 0 {
                        break;
                    }
                    output.write_entire(&buffer[..count])
                        .await
                        .map_err(|error| format!("Staging signed IPA failed: {error}"))?;
                    written += count as u64;
                    let percent = ((written as u128 * 100) / total as u128).min(100) as u64;
                    if percent != previous_percent {
                        emit(callback, 208, percent.to_string());
                        previous_percent = percent;
                    }
                }
                output.close()
                    .await
                    .map_err(|error| format!("Closing staged IPA failed: {error}"))?;
                if written != total {
                    return Err(format!(
                        "Signed IPA staging length mismatch: expected {total}, wrote {written}"
                    ));
                }
                // Verify the device itself reports the complete staged length
                // before issuing a destructive replacement command.
                let remote_info = afc
                    .get_file_info_raw("PublicStaging/idevice.ipa")
                    .await
                    .map_err(|error| format!("Cannot verify staged IPA size: {error}"))?;
                let remote_size = remote_info
                    .get("st_size")
                    .and_then(|value| value.parse::<u64>().ok())
                    .ok_or_else(|| "Staged IPA has no readable device-side size".to_string())?;
                if remote_size != total {
                    return Err(format!(
                        "Device-side IPA length mismatch: expected {total}, found {remote_size}"
                    ));
                }
                emit(callback, 209, "Signed IPA fully staged and size-verified on device");
                drop(afc);

                let mut installation_proxy =
                    InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)
                        .await
                        .map_err(|error| format!("Self-update installation_proxy failed: {error}"))?;
                let mut options = plist::Dictionary::new();
                options.insert(
                    "CFBundleIdentifier".to_string(),
                    plist::Value::String(bundle_id.clone()),
                );

                // The public API sends Upgrade and waits for real iOS completion.
                // Do not emit 210 here: transmission is not separately observable.
                installation_proxy
                    .upgrade_with_callback(
                        "PublicStaging/idevice.ipa",
                        Some(plist::Value::Dictionary(options)),
                        |(percent, callback)| async move {
                            emit(callback, 206, percent.to_string());
                        },
                        callback,
                    )
                    .await
                    .map_err(|error| format!("Self-update Upgrade failed: {error}"))?;
            } else if is_upgrade {
                upgrade_package_with_callback_rsd(
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
                .map_err(|error| format!("Direct upgrade failed: {error}"))?;
            } else {
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
            }

            emit(callback, 207, "Installation complete");
            Ok(())
        },
    )
    .await
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
    let Some(callback) = callback else {
        return false;
    };
    if device_ip.is_null() || pairing_path.is_null() || bundle_id.is_null() {
        return false;
    }

    let Ok(device_ip) = CStr::from_ptr(device_ip).to_str().map(str::to_owned) else {
        return false;
    };
    let Ok(pairing_path) = CStr::from_ptr(pairing_path).to_str().map(PathBuf::from) else {
        return false;
    };
    let Ok(bundle_id) = CStr::from_ptr(bundle_id).to_str().map(str::to_owned) else {
        return false;
    };

    thread::spawn(move || {
        emit(callback, 301, format!("Starting uninstall for {bundle_id}"));
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                emit(callback, -5, format!("Uninstall runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            if let Err(error) =
                run_gate4_uninstall(device_ip, pairing_path, bundle_id, callback).await
            {
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
    let tunnel_stream = timeout(
        Duration::from_secs(8),
        TcpStream::connect((ip, tunnel_port)),
    )
    .await
    .map_err(|_| format!("Timed out reaching RPPairing tunnel at {device_ip}:{tunnel_port}"))?
    .map_err(|error| {
        format!("Unable to reach RPPairing tunnel at {device_ip}:{tunnel_port}: {error}")
    })?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|error| format!("TLS-PSK CDTunnel failed: {error}"))?;
    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|error| format!("Invalid tunnel client address: {error}"))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|error| format!("Invalid tunnel server address: {error}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    emit(
        callback,
        303,
        format!("CDTunnel established; RSD port {rsd_port}"),
    );

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
    emit(
        callback,
        304,
        format!("RSD established; {} services", handshake.services.len()),
    );

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

#[cfg(test)]
mod diagnostic_error_tests {
    use super::*;

    #[test]
    fn socket_errors_keep_kind_and_os_code() {
        let reset = idevice::IdeviceError::Socket(std::io::Error::from_raw_os_error(54));
        let text = error_detail(&reset);
        assert!(text.starts_with("device socket io failed [idevice code 1"), "{text}");
        assert!(text.contains("io kind ConnectionReset"), "{text}");
        assert!(text.contains("os error 54"), "{text}");
    }

    #[test]
    fn end_of_stream_is_distinguished_from_reset() {
        let eof = idevice::IdeviceError::Socket(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "early eof"));
        let text = error_detail(&eof);
        assert!(text.contains("io kind UnexpectedEof"), "{text}");
        assert!(text.contains("no os error"), "{text}");
        assert!(text.contains("<- early eof"), "the source chain is preserved: {text}");
    }

    #[test]
    fn broken_pipe_and_refusal_keep_their_codes() {
        let pipe = error_detail(&idevice::IdeviceError::Socket(std::io::Error::from_raw_os_error(32)));
        assert!(pipe.contains("io kind BrokenPipe") && pipe.contains("os error 32"), "{pipe}");
        let refused = io_error_detail(&std::io::Error::from_raw_os_error(61));
        assert!(refused.contains("io kind ConnectionRefused") && refused.contains("os error 61"), "{refused}");
    }

    #[test]
    fn protocol_errors_are_not_reported_as_socket_errors() {
        let text = error_detail(&idevice::IdeviceError::UnexpectedResponse("missing handshake response".into()));
        assert!(!text.contains("io kind"), "{text}");
        assert!(text.contains("idevice code"), "{text}");
    }
}
