/* DX12 render target implementation: offscreen RT creation, bind, clear,
 * viewport, automatic resource state transitions. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

void nm_transition(nmCommandBuffer* cb,
                   nmRenderTarget* rt,
                   D3D12_RESOURCE_STATES new_state) {
    if (!cb || !rt || !rt->color_resource) return;
    if (rt->color_state == new_state) return;

    D3D12_RESOURCE_BARRIER b;
    memset(&b, 0, sizeof(b));
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
    b.Transition.pResource = rt->color_resource;
    b.Transition.StateBefore = rt->color_state;
    b.Transition.StateAfter = new_state;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(cb->list, 1, &b);
    rt->color_state = new_state;
}

nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height) {
    if (!device || width <= 0 || height <= 0) return NULL;

    nmRenderTarget* rt = (nmRenderTarget*)calloc(1, sizeof(nmRenderTarget));
    if (!rt) {
        nm_log(nmLogLevelError, "render_target", "out of memory");
        return NULL;
    }
    rt->owner = device;
    rt->width = width;
    rt->height = height;
    rt->is_swapchain_owned = false;
    rt->rtv_index = -1;
    rt->dsv_index = -1;

    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof(hp));
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;

    /* Color resource. */
    {
        D3D12_RESOURCE_DESC rd;
        memset(&rd, 0, sizeof(rd));
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Alignment = 0;
        rd.Width = (UINT64)width;
        rd.Height = (UINT)height;
        rd.DepthOrArraySize = 1;
        rd.MipLevels = 1;
        rd.Format = NM_COLOR_FORMAT;
        rd.SampleDesc.Count = 1;
        rd.SampleDesc.Quality = 0;
        rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;

        D3D12_CLEAR_VALUE cv;
        memset(&cv, 0, sizeof(cv));
        cv.Format = NM_COLOR_FORMAT;
        cv.Color[0] = 0.0f; cv.Color[1] = 0.0f;
        cv.Color[2] = 0.0f; cv.Color[3] = 0.0f;

        if (FAILED(ID3D12Device_CreateCommittedResource(device->device, &hp,
                D3D12_HEAP_FLAG_NONE, &rd,
                D3D12_RESOURCE_STATE_RENDER_TARGET, &cv,
                &IID_ID3D12Resource, (void**)&rt->color_resource))) {
            nm_log(nmLogLevelError, "render_target", "CreateCommittedResource (color) failed");
            goto fail;
        }
        rt->color_state = D3D12_RESOURCE_STATE_RENDER_TARGET;
    }

    /* RTV. */
    rt->rtv_index = nm_alloc_rtv_slot(device);
    if (rt->rtv_index < 0) goto fail;
    {
        D3D12_CPU_DESCRIPTOR_HANDLE h = nm_rtv_cpu_handle(device, rt->rtv_index);
        ID3D12Device_CreateRenderTargetView(device->device, rt->color_resource, NULL, h);
    }

    /* Stencil resource. */
    {
        D3D12_RESOURCE_DESC rd;
        memset(&rd, 0, sizeof(rd));
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = (UINT64)width;
        rd.Height = (UINT)height;
        rd.DepthOrArraySize = 1;
        rd.MipLevels = 1;
        rd.Format = NM_STENCIL_FORMAT;
        rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;

        D3D12_CLEAR_VALUE cv;
        memset(&cv, 0, sizeof(cv));
        cv.Format = NM_STENCIL_FORMAT;
        cv.DepthStencil.Depth = 1.0f;
        cv.DepthStencil.Stencil = 0;

        if (FAILED(ID3D12Device_CreateCommittedResource(device->device, &hp,
                D3D12_HEAP_FLAG_NONE, &rd,
                D3D12_RESOURCE_STATE_DEPTH_WRITE, &cv,
                &IID_ID3D12Resource, (void**)&rt->stencil_resource))) {
            nm_log(nmLogLevelError, "render_target", "CreateCommittedResource (stencil) failed");
            goto fail;
        }
    }

    /* DSV. */
    rt->dsv_index = nm_alloc_dsv_slot(device);
    if (rt->dsv_index < 0) goto fail;
    {
        D3D12_DEPTH_STENCIL_VIEW_DESC dsvd;
        memset(&dsvd, 0, sizeof(dsvd));
        dsvd.Format = NM_STENCIL_FORMAT;
        dsvd.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
        dsvd.Flags = D3D12_DSV_FLAG_NONE;
        D3D12_CPU_DESCRIPTOR_HANDLE h = nm_dsv_cpu_handle(device, rt->dsv_index);
        ID3D12Device_CreateDepthStencilView(device->device, rt->stencil_resource, &dsvd, h);
    }

    return rt;

fail:
    nmDestroyRenderTarget(rt);
    return NULL;
}

void nmDestroyRenderTarget(nmRenderTarget* self) {
    if (!self) return;
    if (self->is_swapchain_owned) {
        nm_log(nmLogLevelWarn, "render_target",
            "nmDestroyRenderTarget called on swapchain-owned target (ignored)");
        return;
    }

    if (self->color_resource) {
        ID3D12Resource_Release(self->color_resource);
        self->color_resource = NULL;
    }
    if (self->stencil_resource) {
        ID3D12Resource_Release(self->stencil_resource);
        self->stencil_resource = NULL;
    }
    if (self->owner) {
        nm_free_rtv_slot(self->owner, self->rtv_index);
        nm_free_dsv_slot(self->owner, self->dsv_index);
    }
    self->rtv_index = -1;
    self->dsv_index = -1;
    free(self);
}

void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target) {
    if (!self || !target) return;

    nm_transition(self, target, D3D12_RESOURCE_STATE_RENDER_TARGET);

    D3D12_CPU_DESCRIPTOR_HANDLE rtv = nm_rtv_cpu_handle(self->owner, target->rtv_index);
    D3D12_CPU_DESCRIPTOR_HANDLE dsv = nm_dsv_cpu_handle(self->owner, target->dsv_index);
    ID3D12GraphicsCommandList_OMSetRenderTargets(self->list, 1, &rtv, FALSE, &dsv);

    D3D12_VIEWPORT vp;
    vp.TopLeftX = 0.0f; vp.TopLeftY = 0.0f;
    vp.Width = (FLOAT)target->width; vp.Height = (FLOAT)target->height;
    vp.MinDepth = 0.0f; vp.MaxDepth = 1.0f;
    ID3D12GraphicsCommandList_RSSetViewports(self->list, 1, &vp);

    D3D12_RECT sc;
    sc.left = 0; sc.top = 0;
    sc.right = target->width; sc.bottom = target->height;
    ID3D12GraphicsCommandList_RSSetScissorRects(self->list, 1, &sc);

    self->current_rt = target;
}

void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height) {
    if (!self) return;
    D3D12_VIEWPORT vp;
    vp.TopLeftX = x; vp.TopLeftY = y;
    vp.Width = width; vp.Height = height;
    vp.MinDepth = 0.0f; vp.MaxDepth = 1.0f;
    ID3D12GraphicsCommandList_RSSetViewports(self->list, 1, &vp);

    D3D12_RECT sc;
    sc.left = (LONG)x; sc.top = (LONG)y;
    sc.right = (LONG)(x + width); sc.bottom = (LONG)(y + height);
    ID3D12GraphicsCommandList_RSSetScissorRects(self->list, 1, &sc);
}

void nmSetScissor(nmCommandBuffer* self, int x, int y, int width, int height) {
    if (!self) return;
    D3D12_RECT sc;
    sc.left = (LONG)x;
    sc.top = (LONG)y;
    sc.right = (LONG)(x + width);
    sc.bottom = (LONG)(y + height);
    ID3D12GraphicsCommandList_RSSetScissorRects(self->list, 1, &sc);
}

void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a) {
    if (!self || !self->current_rt) return;
    const FLOAT color[4] = { r, g, b, a };
    D3D12_CPU_DESCRIPTOR_HANDLE h = nm_rtv_cpu_handle(self->owner, self->current_rt->rtv_index);
    ID3D12GraphicsCommandList_ClearRenderTargetView(self->list, h, color, 0, NULL);
}

void nmClearStencil(nmCommandBuffer* self, uint8_t value) {
    if (!self || !self->current_rt) return;
    D3D12_CPU_DESCRIPTOR_HANDLE h = nm_dsv_cpu_handle(self->owner, self->current_rt->dsv_index);
    ID3D12GraphicsCommandList_ClearDepthStencilView(self->list, h,
        D3D12_CLEAR_FLAG_STENCIL, 1.0f, value, 0, NULL);
}

int nmReadbackRenderTarget(nmRenderTarget* self, void* out_rgba, size_t out_size) {
    if (!self || !out_rgba || !self->owner || !self->color_resource) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: invalid argument");
        return -1;
    }
    if (self->is_swapchain_owned) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: swapchain-owned target is not supported");
        return -1;
    }

    nmDevice* dev = self->owner;
    const UINT width = (UINT)self->width;
    const UINT height = (UINT)self->height;
    const size_t required = (size_t)width * (size_t)height * 4u;
    if (out_size < required) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: out_size %zu < required %zu",
            out_size, required);
        return -1;
    }

    /* Query the copyable layout (placed footprint) of subresource 0. The row
     * pitch returned here is rounded up to D3D12_TEXTURE_DATA_PITCH_ALIGNMENT
     * (256), which we must use when copying out of the readback heap. */
    D3D12_RESOURCE_DESC src_desc;
    self->color_resource->lpVtbl->GetDesc(self->color_resource, &src_desc);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT   num_rows = 0;
    UINT64 row_size_bytes = 0;
    UINT64 total_bytes = 0;
    ID3D12Device_GetCopyableFootprints(dev->device, &src_desc,
        0, 1, 0, &footprint, &num_rows, &row_size_bytes, &total_bytes);

    /* Allocate a one-shot readback heap buffer sized to the placed footprint. */
    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof(hp));
    hp.Type = D3D12_HEAP_TYPE_READBACK;

    D3D12_RESOURCE_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Width = total_bytes;
    bd.Height = 1;
    bd.DepthOrArraySize = 1;
    bd.MipLevels = 1;
    bd.Format = DXGI_FORMAT_UNKNOWN;
    bd.SampleDesc.Count = 1;
    bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    bd.Flags = D3D12_RESOURCE_FLAG_NONE;

    ID3D12Resource* readback = NULL;
    if (FAILED(ID3D12Device_CreateCommittedResource(dev->device, &hp,
            D3D12_HEAP_FLAG_NONE, &bd,
            D3D12_RESOURCE_STATE_COPY_DEST, NULL,
            &IID_ID3D12Resource, (void**)&readback))) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: readback heap allocation failed");
        return -1;
    }

    /* Acquire a CB from the pool, transition RT -> COPY_SOURCE, copy, then
     * transition back so subsequent paints find the RT in its prior state. */
    nmCommandBuffer* cb = nmAcquireCommandBuffer(dev);
    if (!cb) {
        ID3D12Resource_Release(readback);
        return -1;
    }
    nmBeginCommandBuffer(cb);

    const D3D12_RESOURCE_STATES prev_state = self->color_state;
    nm_transition(cb, self, D3D12_RESOURCE_STATE_COPY_SOURCE);

    D3D12_TEXTURE_COPY_LOCATION src;
    memset(&src, 0, sizeof(src));
    src.pResource = self->color_resource;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;

    D3D12_TEXTURE_COPY_LOCATION dst;
    memset(&dst, 0, sizeof(dst));
    dst.pResource = readback;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = footprint;

    ID3D12GraphicsCommandList_CopyTextureRegion(cb->list, &dst, 0, 0, 0, &src, NULL);

    nm_transition(cb, self, prev_state);

    nmEndCommandBuffer(cb);
    nmSubmitCommandBuffer(cb, dev);
    nmWaitForCommandBuffer(cb);
    nmReleaseCommandBuffer(cb);

    /* Map and copy out row-by-row, dropping the per-row pitch padding. The
     * underlying format is NM_COLOR_FORMAT (R8G8B8A8_UNORM) so the channel
     * order already matches the public RGBA8 contract — no swizzle needed. */
    void* mapped = NULL;
    D3D12_RANGE read_range;
    read_range.Begin = 0;
    read_range.End = (SIZE_T)total_bytes;
    if (FAILED(ID3D12Resource_Map(readback, 0, &read_range, &mapped))) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: readback Map failed");
        ID3D12Resource_Release(readback);
        return -1;
    }

    const uint8_t* src_bytes = (const uint8_t*)mapped + (size_t)footprint.Offset;
    uint8_t* dst_bytes = (uint8_t*)out_rgba;
    const size_t row_bytes = (size_t)width * 4u;
    const size_t src_pitch = (size_t)footprint.Footprint.RowPitch;
    for (UINT y = 0; y < height; y++) {
        memcpy(dst_bytes + (size_t)y * row_bytes,
               src_bytes + (size_t)y * src_pitch,
               row_bytes);
    }

    D3D12_RANGE write_range = { 0, 0 };
    ID3D12Resource_Unmap(readback, 0, &write_range);
    ID3D12Resource_Release(readback);

    return 0;
}

#endif /* _WIN32 */
