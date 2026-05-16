/* DX12 buffer implementation: UPLOAD heap with persistent mapping for all
 * usages. Vertex/Index/Constant binds share the same underlying resource. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage) {
    if (!device || size == 0) return NULL;

    nmBuffer* b = (nmBuffer*)calloc(1, sizeof(nmBuffer));
    if (!b) {
        nm_log(nmLogLevelError, "buffer", "out of memory");
        return NULL;
    }
    b->size = size;
    b->usage = usage;

    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof(hp));
    hp.Type = D3D12_HEAP_TYPE_UPLOAD;

    D3D12_RESOURCE_DESC rd;
    memset(&rd, 0, sizeof(rd));
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = (UINT64)size;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc.Count = 1;
    rd.SampleDesc.Quality = 0;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    rd.Flags = D3D12_RESOURCE_FLAG_NONE;

    if (FAILED(ID3D12Device_CreateCommittedResource(device->device, &hp,
            D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
            &IID_ID3D12Resource, (void**)&b->resource))) {
        nm_log(nmLogLevelError, "buffer", "CreateCommittedResource failed (size=%zu)", size);
        free(b);
        return NULL;
    }

    /* Persistently map: UPLOAD heap is CPU-coherent, no need to unmap. */
    D3D12_RANGE read_range = { 0, 0 };
    if (FAILED(ID3D12Resource_Map(b->resource, 0, &read_range, &b->mapped_ptr))) {
        nm_log(nmLogLevelError, "buffer", "Map failed");
        ID3D12Resource_Release(b->resource);
        free(b);
        return NULL;
    }

    b->gpu_va = ID3D12Resource_GetGPUVirtualAddress(b->resource);
    return b;
}

void nmDestroyBuffer(nmBuffer* self) {
    if (!self) return;
    if (self->resource) {
        ID3D12Resource_Unmap(self->resource, 0, NULL);
        ID3D12Resource_Release(self->resource);
    }
    free(self);
}

void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset) {
    if (!self || !data || !self->mapped_ptr) return;
    if (offset + size > self->size) {
        nm_log(nmLogLevelError, "buffer",
            "upload out of range (offset=%zu size=%zu buf=%zu)", offset, size, self->size);
        return;
    }
    memcpy((char*)self->mapped_ptr + offset, data, size);
}

void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot,
                        size_t stride, size_t offset) {
    if (!self || !buf) return;
    D3D12_VERTEX_BUFFER_VIEW view;
    view.BufferLocation = buf->gpu_va + (UINT64)offset;
    view.SizeInBytes = (UINT)(buf->size - offset);
    view.StrideInBytes = (UINT)stride;
    ID3D12GraphicsCommandList_IASetVertexBuffers(self->list, (UINT)slot, 1, &view);
}

void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf,
                       nmIndexFormat fmt, size_t offset) {
    if (!self || !buf) return;
    D3D12_INDEX_BUFFER_VIEW view;
    view.BufferLocation = buf->gpu_va + (UINT64)offset;
    view.SizeInBytes = (UINT)(buf->size - offset);
    view.Format = (fmt == nmIndexFormatU16) ? DXGI_FORMAT_R16_UINT : DXGI_FORMAT_R32_UINT;
    ID3D12GraphicsCommandList_IASetIndexBuffer(self->list, &view);
}

void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot,
                          size_t offset, size_t size) {
    (void)size;  /* Root CBV uses 64 KiB max from the address; no explicit size. */
    if (!self || !buf || !self->current_pipeline) return;
    nmRootSignature* sig = self->current_pipeline->root_signature;
    if (!sig) return;

    for (int i = 0; i < sig->param_count; i++) {
        if (sig->params[i].type == nmRootBindingTypeConstantBuffer
                && sig->params[i].slot == slot) {
            ID3D12GraphicsCommandList_SetGraphicsRootConstantBufferView(
                self->list, (UINT)sig->params[i].root_param_index,
                buf->gpu_va + (UINT64)offset);
            return;
        }
    }
    nm_log(nmLogLevelWarn, "buffer",
        "nmBindConstantBuffer: no ConstantBuffer binding for slot %d in current pipeline", slot);
}

#endif /* _WIN32 */
