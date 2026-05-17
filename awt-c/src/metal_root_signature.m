/* Metal "root signature": pure binding-table struct. Metal has no API-level
 * root signature object — buffer / texture / sampler bindings are reached
 * directly through MSL [[buffer(N)]] / [[texture(N)]] / [[sampler(N)]]
 * attributes. We keep the (type, stage, slot) table so the existing
 * nmBindConstantBuffer / nmBindTexture lookups (driven by the DX12 API
 * shape) work uniformly. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

nmRootSignature* nmCreateRootSignature(nmDevice* device,
                                       const nmRootBinding* bindings, int count) {
    (void)device;
    if (count < 0) count = 0;
    if (count > NM_MAX_ROOT_PARAMS) {
        nm_log(nmLogLevelError, "root_signature",
            "binding count %d exceeds max %d", count, NM_MAX_ROOT_PARAMS);
        return NULL;
    }

    nmRootSignature* rs = (nmRootSignature*)calloc(1, sizeof(nmRootSignature));
    if (!rs) return NULL;
    rs->param_count = count;
    for (int i = 0; i < count; i++) {
        rs->params[i].type = bindings[i].type;
        rs->params[i].stage = bindings[i].stage;
        rs->params[i].slot = bindings[i].slot;
    }
    return rs;
}

void nmDestroyRootSignature(nmRootSignature* self) {
    if (!self) return;
    free(self);
}

#endif /* __APPLE__ */
