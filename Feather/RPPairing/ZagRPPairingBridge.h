#ifndef ZagRPPairingBridge_h
#define ZagRPPairingBridge_h

#include <stdbool.h>

typedef void (*ZagRPPairingCallback)(int code, const char *message);

char *zag_rppairing_core_version(void);
void zag_rppairing_string_free(char *value);

bool zag_rppairing_start(
    const char *host_name,
    const char *output_path,
    ZagRPPairingCallback callback
);

bool zag_gate2_probe(
    const char *device_ip,
    const char *lockdown_output_path,
    ZagRPPairingCallback callback
);

bool zag_installed_apps(
    const char *device_ip,
    const char *pairing_path,
    ZagRPPairingCallback callback
);

bool zag_installed_app_icons(
    const char *device_ip,
    const char *pairing_path,
    const char *bundle_ids,
    const char *output_dir,
    ZagRPPairingCallback callback
);

bool zag_gate4_install(
    const char *device_ip,
    const char *pairing_path,
    const char *ipa_path,
    ZagRPPairingCallback callback
);

bool zag_gate4_uninstall(
    const char *device_ip,
    const char *pairing_path,
    const char *bundle_id,
    ZagRPPairingCallback callback
);

#endif
