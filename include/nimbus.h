#ifndef NIMBUS_H
#define NIMBUS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Build-sanity entry point. Will be replaced by the real public ABI
 * (windows, components, events) once the framework grows. */
int nimbus_double(int x);

/* Backend identification string (e.g. "3.4.0 Win32 WGL ..."). */
const char* nimbus_backend_version(void);

#ifdef __cplusplus
}
#endif

#endif /* NIMBUS_H */
