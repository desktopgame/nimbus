#ifndef NIMBUS_AWT_C_INTERNAL_H
#define NIMBUS_AWT_C_INTERNAL_H

/* awt-c の内部ヘッダー。translate-c 経由で awt (Zig) 層からのみ参照される。
 * libnimbus 利用者には露出しない。 */

int nimbus_awt_test_double(int x);

/* GLFW shim. Does not expose GLFW types to keep the binding surface tiny. */
const char* nimbus_glfw_version_string(void);
int nimbus_glfw_init(void);
void nimbus_glfw_terminate(void);

#endif /* NIMBUS_AWT_C_INTERNAL_H */
