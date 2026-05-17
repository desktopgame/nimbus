/* Metal graphics pipeline: MTLRenderPipelineState + MTLDepthStencilState +
 * vertex descriptor + topology / cull / winding meta. Mirrors dx12_pipeline.c. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

/* ─── Enum mappings ───────────────────────────────────────────────────── */

static MTLPrimitiveTopologyClass topology_class(nmPrimitiveTopology t) {
    switch (t) {
        case nmPrimitiveTopologyTriangleList: return MTLPrimitiveTopologyClassTriangle;
        case nmPrimitiveTopologyLineList:     return MTLPrimitiveTopologyClassLine;
        case nmPrimitiveTopologyPointList:    return MTLPrimitiveTopologyClassPoint;
    }
    return MTLPrimitiveTopologyClassUnspecified;
}

static MTLPrimitiveType primitive_type(nmPrimitiveTopology t) {
    switch (t) {
        case nmPrimitiveTopologyTriangleList: return MTLPrimitiveTypeTriangle;
        case nmPrimitiveTopologyLineList:     return MTLPrimitiveTypeLine;
        case nmPrimitiveTopologyPointList:    return MTLPrimitiveTypePoint;
    }
    return MTLPrimitiveTypeTriangle;
}

static MTLStencilOperation stencil_op(nmStencilOp op) {
    switch (op) {
        case nmStencilOpKeep:          return MTLStencilOperationKeep;
        case nmStencilOpZero:          return MTLStencilOperationZero;
        case nmStencilOpReplace:       return MTLStencilOperationReplace;
        case nmStencilOpIncrementSat:  return MTLStencilOperationIncrementClamp;
        case nmStencilOpDecrementSat:  return MTLStencilOperationDecrementClamp;
        case nmStencilOpInvert:        return MTLStencilOperationInvert;
        case nmStencilOpIncrementWrap: return MTLStencilOperationIncrementWrap;
        case nmStencilOpDecrementWrap: return MTLStencilOperationDecrementWrap;
    }
    return MTLStencilOperationKeep;
}

static MTLCompareFunction compare_func(nmCompareFunc f) {
    switch (f) {
        case nmCompareFuncNever:        return MTLCompareFunctionNever;
        case nmCompareFuncLess:         return MTLCompareFunctionLess;
        case nmCompareFuncEqual:        return MTLCompareFunctionEqual;
        case nmCompareFuncLessEqual:    return MTLCompareFunctionLessEqual;
        case nmCompareFuncGreater:      return MTLCompareFunctionGreater;
        case nmCompareFuncNotEqual:     return MTLCompareFunctionNotEqual;
        case nmCompareFuncGreaterEqual: return MTLCompareFunctionGreaterEqual;
        case nmCompareFuncAlways:       return MTLCompareFunctionAlways;
    }
    return MTLCompareFunctionAlways;
}

static void configure_blend(MTLRenderPipelineColorAttachmentDescriptor* ca,
                            nmBlendMode mode, bool color_write_enable) {
    ca.writeMask = color_write_enable
        ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    switch (mode) {
        case nmBlendModeNone:
            ca.blendingEnabled = NO;
            break;
        case nmBlendModeAlpha:
            ca.blendingEnabled = YES;
            ca.rgbBlendOperation = MTLBlendOperationAdd;
            ca.alphaBlendOperation = MTLBlendOperationAdd;
            ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
            ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            break;
        case nmBlendModePremultipliedAlpha:
            ca.blendingEnabled = YES;
            ca.rgbBlendOperation = MTLBlendOperationAdd;
            ca.alphaBlendOperation = MTLBlendOperationAdd;
            ca.sourceRGBBlendFactor = MTLBlendFactorOne;
            ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
            ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            break;
    }
}

/* Build the vertex descriptor matching the input-layout enums. Vertex streams
 * are pulled from MTL buffer index NM_VERTEX_BUFFER_INDEX_BASE - slot (slot 0
 * → index 30). This avoids colliding with constant buffer indices at 0..N. */
static MTLVertexDescriptor* build_vertex_descriptor(nmVertexLayout layout) {
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    NSUInteger stream_index = (NSUInteger)NM_VERTEX_BUFFER_INDEX_BASE;
    switch (layout) {
        case nmVertexLayoutVertex2D: {
            vd.attributes[0].format = MTLVertexFormatFloat2;
            vd.attributes[0].offset = 0;
            vd.attributes[0].bufferIndex = stream_index;
            vd.layouts[stream_index].stride = 8;
            vd.layouts[stream_index].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[stream_index].stepRate = 1;
            return vd;
        }
        case nmVertexLayoutVertexTexCoord2D: {
            vd.attributes[0].format = MTLVertexFormatFloat2;
            vd.attributes[0].offset = 0;
            vd.attributes[0].bufferIndex = stream_index;
            vd.attributes[1].format = MTLVertexFormatFloat2;
            vd.attributes[1].offset = 8;
            vd.attributes[1].bufferIndex = stream_index;
            vd.layouts[stream_index].stride = 16;
            vd.layouts[stream_index].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[stream_index].stepRate = 1;
            return vd;
        }
    }
    return nil;
}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc) {
    if (!device || !desc || !desc->root_signature
            || !desc->vertex_shader || !desc->pixel_shader) {
        nm_log(nmLogLevelError, "pipeline", "missing required field in nmPipelineDesc");
        return NULL;
    }
    if (!desc->vertex_shader->function || !desc->pixel_shader->function) {
        nm_log(nmLogLevelError, "pipeline", "shader has nil MTLFunction");
        return NULL;
    }

    nmPipeline* p = (nmPipeline*)calloc(1, sizeof(nmPipeline));
    if (!p) return NULL;
    p->root_signature = desc->root_signature;
    p->primitive_type = primitive_type(desc->topology);
    p->stencil_enabled = desc->stencil.enable;

    @autoreleasepool {
        MTLVertexDescriptor* vd = build_vertex_descriptor(desc->vertex_layout);
        if (!vd) {
            nm_log(nmLogLevelError, "pipeline", "unknown vertex layout %d",
                (int)desc->vertex_layout);
            free(p);
            return NULL;
        }

        MTLRenderPipelineDescriptor* psd = [[MTLRenderPipelineDescriptor alloc] init];
        psd.vertexFunction = desc->vertex_shader->function;
        psd.fragmentFunction = desc->pixel_shader->function;
        psd.vertexDescriptor = vd;
        psd.inputPrimitiveTopology = topology_class(desc->topology);
        psd.rasterSampleCount = 1;

        psd.colorAttachments[0].pixelFormat = NM_COLOR_FORMAT;
        configure_blend(psd.colorAttachments[0], desc->blend, desc->color_write_enable);

        /* nimbus carries a stencil-only attachment; depth is unused. */
        psd.stencilAttachmentPixelFormat = NM_STENCIL_FORMAT;

        NSError* err = nil;
        id<MTLRenderPipelineState> pso =
            [device->device newRenderPipelineStateWithDescriptor:psd error:&err];
        [psd release];

        if (!pso) {
            const char* msg = err ? [[err localizedDescription] UTF8String] : "(no message)";
            nm_log(nmLogLevelError, "pipeline", "newRenderPipelineStateWithDescriptor: %s", msg);
            free(p);
            return NULL;
        }
        p->pso = [pso retain];
        [pso release];

        /* Depth/Stencil state. Depth is always disabled (no depth buffer). */
        MTLDepthStencilDescriptor* dsd = [[MTLDepthStencilDescriptor alloc] init];
        dsd.depthCompareFunction = MTLCompareFunctionAlways;
        dsd.depthWriteEnabled = NO;
        if (desc->stencil.enable) {
            MTLStencilDescriptor* sd = [[MTLStencilDescriptor alloc] init];
            sd.stencilCompareFunction = compare_func(desc->stencil.compare_func);
            sd.stencilFailureOperation = stencil_op(desc->stencil.fail_op);
            sd.depthFailureOperation = stencil_op(desc->stencil.depth_fail_op);
            sd.depthStencilPassOperation = stencil_op(desc->stencil.pass_op);
            sd.readMask = desc->stencil.read_mask;
            sd.writeMask = desc->stencil.write_mask;
            dsd.frontFaceStencil = sd;
            dsd.backFaceStencil = sd;
            [sd release];
        }
        id<MTLDepthStencilState> dss =
            [device->device newDepthStencilStateWithDescriptor:dsd];
        [dsd release];
        if (!dss) {
            nm_log(nmLogLevelError, "pipeline", "newDepthStencilStateWithDescriptor failed");
            [p->pso release];
            free(p);
            return NULL;
        }
        p->dss = [dss retain];
        [dss release];
    }

    return p;
}

void nmDestroyPipeline(nmPipeline* self) {
    if (!self) return;
    if (self->dss) [self->dss release];
    if (self->pso) [self->pso release];
    free(self);
}

void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline) {
    if (!self || !pipeline) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;
    [self->encoder setRenderPipelineState:pipeline->pso];
    [self->encoder setDepthStencilState:pipeline->dss];
    if (pipeline->stencil_enabled) {
        [self->encoder setStencilReferenceValue:self->stencil_ref];
    }
    self->current_pipeline = pipeline;
}

void nmSetStencilRef(nmCommandBuffer* self, uint32_t value) {
    if (!self) return;
    self->stencil_ref = value;
    if (self->encoder) {
        [self->encoder setStencilReferenceValue:value];
    }
}

#endif /* __APPLE__ */
