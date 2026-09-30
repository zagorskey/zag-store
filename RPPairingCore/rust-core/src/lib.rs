use std::ffi::{c_char, CString};

#[no_mangle]
pub extern "C" fn zag_rppairing_core_version() -> *mut c_char {
    CString::new("Zag RPPairing Core 0.1")
        .expect("static string")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn zag_rppairing_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

// Gate 1 intentionally starts with the ABI boundary only.
// The next milestone ports idevice's RpPairingSocket host flow here and
// exposes PIN + completion callbacks to Swift.
