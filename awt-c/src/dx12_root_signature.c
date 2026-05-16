/* DX12 root signature implementation.
 *
 * Phase 1 mapping:
 *   ConstantBuffer  -> Root CBV (no descriptor heap)
 *   Texture         -> Descriptor Table (size 1, SRV in CBV/SRV/UAV heap)
 *
 * Static samplers (s0..s3) are baked into every root signature. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* Built-in samplers per sampler.md. */
static const D3D12_STATIC_SAMPLER_DESC nm_static_samplers[4] = {
    /* s0: Linear + Clamp */
    {
        .Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR,
        .AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .MipLODBias = 0.0f,
        .MaxAnisotropy = 1,
        .ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS,
        .BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0.0f, .MaxLOD = D3D12_FLOAT32_MAX,
        .ShaderRegister = 0, .RegisterSpace = 0,
        .ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL,
    },
    /* s1: Linear + Wrap */
    {
        .Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR,
        .AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .MipLODBias = 0.0f,
        .MaxAnisotropy = 1,
        .ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS,
        .BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0.0f, .MaxLOD = D3D12_FLOAT32_MAX,
        .ShaderRegister = 1, .RegisterSpace = 0,
        .ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL,
    },
    /* s2: Point + Clamp */
    {
        .Filter = D3D12_FILTER_MIN_MAG_MIP_POINT,
        .AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .MipLODBias = 0.0f,
        .MaxAnisotropy = 1,
        .ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS,
        .BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0.0f, .MaxLOD = D3D12_FLOAT32_MAX,
        .ShaderRegister = 2, .RegisterSpace = 0,
        .ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL,
    },
    /* s3: Point + Wrap */
    {
        .Filter = D3D12_FILTER_MIN_MAG_MIP_POINT,
        .AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .AddressV = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .MipLODBias = 0.0f,
        .MaxAnisotropy = 1,
        .ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS,
        .BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0.0f, .MaxLOD = D3D12_FLOAT32_MAX,
        .ShaderRegister = 3, .RegisterSpace = 0,
        .ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL,
    },
};

static D3D12_SHADER_VISIBILITY visibility_from_stage(nmShaderStage stage) {
    switch (stage) {
        case nmShaderStageVertex: return D3D12_SHADER_VISIBILITY_VERTEX;
        case nmShaderStagePixel:  return D3D12_SHADER_VISIBILITY_PIXEL;
    }
    return D3D12_SHADER_VISIBILITY_ALL;
}

nmRootSignature* nmCreateRootSignature(nmDevice* device,
                                       const nmRootBinding* bindings, int count) {
    if (!device) return NULL;
    if (count < 0) count = 0;
    if (count > NM_MAX_ROOT_PARAMS) {
        nm_log(nmLogLevelError, "root_signature",
            "binding count %d exceeds max %d", count, NM_MAX_ROOT_PARAMS);
        return NULL;
    }

    nmRootSignature* rs = (nmRootSignature*)calloc(1, sizeof(nmRootSignature));
    if (!rs) return NULL;
    rs->param_count = count;

    D3D12_ROOT_PARAMETER params[NM_MAX_ROOT_PARAMS];
    D3D12_DESCRIPTOR_RANGE ranges[NM_MAX_ROOT_PARAMS];

    for (int i = 0; i < count; i++) {
        const nmRootBinding* b = &bindings[i];
        rs->params[i].type = b->type;
        rs->params[i].slot = b->slot;
        rs->params[i].root_param_index = i;

        memset(&params[i], 0, sizeof(params[i]));
        params[i].ShaderVisibility = visibility_from_stage(b->stage);

        switch (b->type) {
            case nmRootBindingTypeConstantBuffer:
                params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
                params[i].Descriptor.ShaderRegister = (UINT)b->slot;
                params[i].Descriptor.RegisterSpace = 0;
                break;
            case nmRootBindingTypeTexture:
                memset(&ranges[i], 0, sizeof(ranges[i]));
                ranges[i].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
                ranges[i].NumDescriptors = 1;
                ranges[i].BaseShaderRegister = (UINT)b->slot;
                ranges[i].RegisterSpace = 0;
                ranges[i].OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
                params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
                params[i].DescriptorTable.NumDescriptorRanges = 1;
                params[i].DescriptorTable.pDescriptorRanges = &ranges[i];
                break;
        }
    }

    D3D12_ROOT_SIGNATURE_DESC desc;
    memset(&desc, 0, sizeof(desc));
    desc.NumParameters = (UINT)count;
    desc.pParameters = count > 0 ? params : NULL;
    desc.NumStaticSamplers = 4;
    desc.pStaticSamplers = nm_static_samplers;
    desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

    ID3DBlob* serialized = NULL;
    ID3DBlob* errors = NULL;
    HRESULT hr = D3D12SerializeRootSignature(&desc,
        D3D_ROOT_SIGNATURE_VERSION_1_0, &serialized, &errors);
    if (errors) {
        const char* msg = (const char*)ID3D10Blob_GetBufferPointer(errors);
        nm_log(FAILED(hr) ? nmLogLevelError : nmLogLevelWarn, "root_signature",
            "serialize: %s", msg ? msg : "(no message)");
        ID3D10Blob_Release(errors);
    }
    if (FAILED(hr)) {
        if (serialized) ID3D10Blob_Release(serialized);
        free(rs);
        return NULL;
    }

    if (FAILED(ID3D12Device_CreateRootSignature(device->device, 0,
            ID3D10Blob_GetBufferPointer(serialized),
            ID3D10Blob_GetBufferSize(serialized),
            &IID_ID3D12RootSignature, (void**)&rs->root_signature))) {
        nm_log(nmLogLevelError, "root_signature", "CreateRootSignature failed");
        ID3D10Blob_Release(serialized);
        free(rs);
        return NULL;
    }
    ID3D10Blob_Release(serialized);
    return rs;
}

void nmDestroyRootSignature(nmRootSignature* self) {
    if (!self) return;
    if (self->root_signature) ID3D12RootSignature_Release(self->root_signature);
    free(self);
}

#endif /* _WIN32 */
