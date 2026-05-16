/* DX12 graphics pipeline: enum-to-D3D12 mapping, PSO creation, bind. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* ─── Input layouts ───────────────────────────────────────────────────── */

static const D3D12_INPUT_ELEMENT_DESC vertex_2d_elements[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0,
      D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
};
static const D3D12_INPUT_ELEMENT_DESC vertex_texcoord_2d_elements[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0,
      D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8,
      D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
};

static void layout_for(nmVertexLayout v,
                       const D3D12_INPUT_ELEMENT_DESC** out_elems, UINT* out_count) {
    switch (v) {
        case nmVertexLayoutVertex2D:
            *out_elems = vertex_2d_elements;
            *out_count = (UINT)(sizeof(vertex_2d_elements) / sizeof(vertex_2d_elements[0]));
            return;
        case nmVertexLayoutVertexTexCoord2D:
            *out_elems = vertex_texcoord_2d_elements;
            *out_count = (UINT)(sizeof(vertex_texcoord_2d_elements) / sizeof(vertex_texcoord_2d_elements[0]));
            return;
    }
    *out_elems = NULL;
    *out_count = 0;
}

/* ─── Enum mappings ───────────────────────────────────────────────────── */

static D3D12_PRIMITIVE_TOPOLOGY_TYPE topology_type(nmPrimitiveTopology t) {
    switch (t) {
        case nmPrimitiveTopologyTriangleList: return D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        case nmPrimitiveTopologyLineList:     return D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE;
        case nmPrimitiveTopologyPointList:    return D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT;
    }
    return D3D12_PRIMITIVE_TOPOLOGY_TYPE_UNDEFINED;
}

static D3D_PRIMITIVE_TOPOLOGY topology_ia(nmPrimitiveTopology t) {
    switch (t) {
        case nmPrimitiveTopologyTriangleList: return D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
        case nmPrimitiveTopologyLineList:     return D3D_PRIMITIVE_TOPOLOGY_LINELIST;
        case nmPrimitiveTopologyPointList:    return D3D_PRIMITIVE_TOPOLOGY_POINTLIST;
    }
    return D3D_PRIMITIVE_TOPOLOGY_UNDEFINED;
}

static D3D12_STENCIL_OP stencil_op(nmStencilOp op) {
    switch (op) {
        case nmStencilOpKeep:          return D3D12_STENCIL_OP_KEEP;
        case nmStencilOpZero:          return D3D12_STENCIL_OP_ZERO;
        case nmStencilOpReplace:       return D3D12_STENCIL_OP_REPLACE;
        case nmStencilOpIncrementSat:  return D3D12_STENCIL_OP_INCR_SAT;
        case nmStencilOpDecrementSat:  return D3D12_STENCIL_OP_DECR_SAT;
        case nmStencilOpInvert:        return D3D12_STENCIL_OP_INVERT;
        case nmStencilOpIncrementWrap: return D3D12_STENCIL_OP_INCR;
        case nmStencilOpDecrementWrap: return D3D12_STENCIL_OP_DECR;
    }
    return D3D12_STENCIL_OP_KEEP;
}

static D3D12_COMPARISON_FUNC compare_func(nmCompareFunc f) {
    switch (f) {
        case nmCompareFuncNever:        return D3D12_COMPARISON_FUNC_NEVER;
        case nmCompareFuncLess:         return D3D12_COMPARISON_FUNC_LESS;
        case nmCompareFuncEqual:        return D3D12_COMPARISON_FUNC_EQUAL;
        case nmCompareFuncLessEqual:    return D3D12_COMPARISON_FUNC_LESS_EQUAL;
        case nmCompareFuncGreater:      return D3D12_COMPARISON_FUNC_GREATER;
        case nmCompareFuncNotEqual:     return D3D12_COMPARISON_FUNC_NOT_EQUAL;
        case nmCompareFuncGreaterEqual: return D3D12_COMPARISON_FUNC_GREATER_EQUAL;
        case nmCompareFuncAlways:       return D3D12_COMPARISON_FUNC_ALWAYS;
    }
    return D3D12_COMPARISON_FUNC_ALWAYS;
}

static void fill_blend_rt(D3D12_RENDER_TARGET_BLEND_DESC* out,
                          nmBlendMode mode, int color_write_enable) {
    memset(out, 0, sizeof(*out));
    out->LogicOpEnable = FALSE;
    out->LogicOp = D3D12_LOGIC_OP_NOOP;
    out->RenderTargetWriteMask = color_write_enable
        ? D3D12_COLOR_WRITE_ENABLE_ALL : 0;

    switch (mode) {
        case nmBlendModeNone:
            out->BlendEnable = FALSE;
            out->SrcBlend = D3D12_BLEND_ONE;
            out->DestBlend = D3D12_BLEND_ZERO;
            out->BlendOp = D3D12_BLEND_OP_ADD;
            out->SrcBlendAlpha = D3D12_BLEND_ONE;
            out->DestBlendAlpha = D3D12_BLEND_ZERO;
            out->BlendOpAlpha = D3D12_BLEND_OP_ADD;
            break;
        case nmBlendModeAlpha:
            out->BlendEnable = TRUE;
            out->SrcBlend = D3D12_BLEND_SRC_ALPHA;
            out->DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            out->BlendOp = D3D12_BLEND_OP_ADD;
            out->SrcBlendAlpha = D3D12_BLEND_ONE;
            out->DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            out->BlendOpAlpha = D3D12_BLEND_OP_ADD;
            break;
        case nmBlendModePremultipliedAlpha:
            out->BlendEnable = TRUE;
            out->SrcBlend = D3D12_BLEND_ONE;
            out->DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            out->BlendOp = D3D12_BLEND_OP_ADD;
            out->SrcBlendAlpha = D3D12_BLEND_ONE;
            out->DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            out->BlendOpAlpha = D3D12_BLEND_OP_ADD;
            break;
    }
}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc) {
    if (!device || !desc || !desc->root_signature
            || !desc->vertex_shader || !desc->pixel_shader) {
        nm_log(nmLogLevelError, "pipeline", "missing required field in nmPipelineDesc");
        return NULL;
    }

    const D3D12_INPUT_ELEMENT_DESC* layout_elems = NULL;
    UINT layout_count = 0;
    layout_for(desc->vertex_layout, &layout_elems, &layout_count);
    if (!layout_elems) {
        nm_log(nmLogLevelError, "pipeline", "unknown vertex layout %d",
            (int)desc->vertex_layout);
        return NULL;
    }

    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso;
    memset(&pso, 0, sizeof(pso));
    pso.pRootSignature = desc->root_signature->root_signature;

    pso.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(desc->vertex_shader->blob);
    pso.VS.BytecodeLength  = ID3D10Blob_GetBufferSize(desc->vertex_shader->blob);
    pso.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(desc->pixel_shader->blob);
    pso.PS.BytecodeLength  = ID3D10Blob_GetBufferSize(desc->pixel_shader->blob);

    /* Blend. */
    pso.BlendState.AlphaToCoverageEnable = FALSE;
    pso.BlendState.IndependentBlendEnable = FALSE;
    fill_blend_rt(&pso.BlendState.RenderTarget[0], desc->blend, desc->color_write_enable);

    pso.SampleMask = 0xFFFFFFFFu;

    /* Rasterizer: GUI-friendly defaults — no culling, solid fill.
     * nimbus regards CCW as front face (matches GL / Vulkan / Metal); D3D12
     * defaults to CW front, so flip via FrontCounterClockwise = TRUE. */
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.RasterizerState.FrontCounterClockwise = TRUE;
    pso.RasterizerState.DepthBias = 0;
    pso.RasterizerState.DepthBiasClamp = 0.0f;
    pso.RasterizerState.SlopeScaledDepthBias = 0.0f;
    pso.RasterizerState.DepthClipEnable = TRUE;
    pso.RasterizerState.MultisampleEnable = FALSE;
    pso.RasterizerState.AntialiasedLineEnable = FALSE;
    pso.RasterizerState.ForcedSampleCount = 0;
    pso.RasterizerState.ConservativeRaster = D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF;

    /* Depth/Stencil. We never use depth. */
    pso.DepthStencilState.DepthEnable = FALSE;
    pso.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    pso.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    pso.DepthStencilState.StencilEnable = desc->stencil.enable ? TRUE : FALSE;
    pso.DepthStencilState.StencilReadMask = desc->stencil.read_mask;
    pso.DepthStencilState.StencilWriteMask = desc->stencil.write_mask;
    pso.DepthStencilState.FrontFace.StencilFailOp      = stencil_op(desc->stencil.fail_op);
    pso.DepthStencilState.FrontFace.StencilDepthFailOp = stencil_op(desc->stencil.depth_fail_op);
    pso.DepthStencilState.FrontFace.StencilPassOp      = stencil_op(desc->stencil.pass_op);
    pso.DepthStencilState.FrontFace.StencilFunc        = compare_func(desc->stencil.compare_func);
    pso.DepthStencilState.BackFace = pso.DepthStencilState.FrontFace;

    pso.InputLayout.pInputElementDescs = layout_elems;
    pso.InputLayout.NumElements = layout_count;

    pso.IBStripCutValue = D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
    pso.PrimitiveTopologyType = topology_type(desc->topology);

    pso.NumRenderTargets = 1;
    pso.RTVFormats[0] = NM_COLOR_FORMAT;
    pso.DSVFormat = NM_STENCIL_FORMAT;
    pso.SampleDesc.Count = 1;
    pso.SampleDesc.Quality = 0;
    pso.NodeMask = 0;
    pso.Flags = D3D12_PIPELINE_STATE_FLAG_NONE;

    nmPipeline* p = (nmPipeline*)calloc(1, sizeof(nmPipeline));
    if (!p) return NULL;
    p->root_signature = desc->root_signature;
    p->topology = topology_ia(desc->topology);

    if (FAILED(ID3D12Device_CreateGraphicsPipelineState(device->device, &pso,
            &IID_ID3D12PipelineState, (void**)&p->pso))) {
        nm_log(nmLogLevelError, "pipeline", "CreateGraphicsPipelineState failed");
        free(p);
        return NULL;
    }
    return p;
}

void nmDestroyPipeline(nmPipeline* self) {
    if (!self) return;
    if (self->pso) ID3D12PipelineState_Release(self->pso);
    free(self);
}

void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline) {
    if (!self || !pipeline) return;
    ID3D12GraphicsCommandList_SetPipelineState(self->list, pipeline->pso);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(self->list,
        pipeline->root_signature->root_signature);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(self->list, pipeline->topology);
    self->current_pipeline = pipeline;
}

void nmSetStencilRef(nmCommandBuffer* self, uint32_t value) {
    if (!self) return;
    ID3D12GraphicsCommandList_OMSetStencilRef(self->list, (UINT)value);
}

#endif /* _WIN32 */
