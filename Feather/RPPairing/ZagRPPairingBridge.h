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

#endif
