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

#endif /* _WIN32 */
