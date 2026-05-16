#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Backend identification string (e.g. "3.4.0 Win32 WGL ..."). */
const char* nmGetBackendVersion(void);

#ifdef __cplusplus
}
#endif
