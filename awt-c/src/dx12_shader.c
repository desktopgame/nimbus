/* DX12 shader implementation: HLSL runtime compilation via D3DCompile.
 * Entry point is fixed per stage (vsMain / psMain). */

#include "dx12_internal.h"

#ifdef _WIN32

#include <d3dcompiler.h>
#include <stdlib.h>
#include <string.h>

nmShader* nmCompileShader(nmShaderStage stage, const char* source) {
    if (!source) return NULL;

    const char* entry;
    const char* target;
    switch (stage) {
        case nmShaderStageVertex: entry = "vsMain"; target = "vs_5_0"; break;
        case nmShaderStagePixel:  entry = "psMain"; target = "ps_5_0"; break;
        default:
            nm_log(nmLogLevelError, "shader", "unsupported stage %d", (int)stage);
            return NULL;
    }

    UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;
#ifdef NM_DX12_DEBUG
    flags |= D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
#endif

    ID3DBlob* code = NULL;
    ID3DBlob* errors = NULL;
    HRESULT hr = D3DCompile(source, strlen(source), NULL, NULL, NULL,
        entry, target, flags, 0, &code, &errors);

    if (errors) {
        const char* msg = (const char*)ID3D10Blob_GetBufferPointer(errors);
        nm_log(FAILED(hr) ? nmLogLevelError : nmLogLevelWarn, "shader",
            "D3DCompile (%s): %s", entry, msg ? msg : "(no message)");
        ID3D10Blob_Release(errors);
    }

    if (FAILED(hr)) {
        if (code) ID3D10Blob_Release(code);
        return NULL;
    }

    nmShader* sh = (nmShader*)calloc(1, sizeof(nmShader));
    if (!sh) {
        ID3D10Blob_Release(code);
        return NULL;
    }
    sh->stage = stage;
    sh->blob = code;
    return sh;
}

nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size) {
    if (!binary || size == 0) return NULL;

    ID3DBlob* blob = NULL;
    if (FAILED(D3DCreateBlob(size, &blob))) {
        nm_log(nmLogLevelError, "shader", "D3DCreateBlob failed");
        return NULL;
    }
    memcpy(ID3D10Blob_GetBufferPointer(blob), binary, size);

    nmShader* sh = (nmShader*)calloc(1, sizeof(nmShader));
    if (!sh) {
        ID3D10Blob_Release(blob);
        return NULL;
    }
    sh->stage = stage;
    sh->blob = blob;
    return sh;
}

void nmDestroyShader(nmShader* self) {
    if (!self) return;
    if (self->blob) ID3D10Blob_Release(self->blob);
    free(self);
}

#endif /* _WIN32 */
