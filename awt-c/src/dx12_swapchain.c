/* DX12 swapchain implementation: back buffer RTs, resize, present. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* ─── Internal helpers ────────────────────────────────────────────────── */

static int create_stencil_for_target(nmDevice* device,
                                     nmRenderTarget* target,
                                     int width, int height) {
    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof(hp));
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;

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
            &IID_ID3D12Resource, (void**)&target->stencil_resource))) {
        nm_log(nmLogLevelError, "swapchain", "stencil CreateCommittedResource failed");
        return -1;
    }

    target->dsv_index = nm_alloc_dsv_slot(device);
    if (target->dsv_index < 0) return -1;

    D3D12_DEPTH_STENCIL_VIEW_DESC dsvd;
    memset(&dsvd, 0, sizeof(dsvd));
    dsvd.Format = NM_STENCIL_FORMAT;
    dsvd.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
    dsvd.Flags = D3D12_DSV_FLAG_NONE;
    D3D12_CPU_DESCRIPTOR_HANDLE h = nm_dsv_cpu_handle(device, target->dsv_index);
    ID3D12Device_CreateDepthStencilView(device->device, target->stencil_resource, &dsvd, h);
    return 0;
}

int nm_swapchain_allocate_targets(nmSwapchain* self) {
    nmDevice* device = self->owner;
    for (int i = 0; i < NM_SWAPCHAIN_BUFFER_COUNT; i++) {
        nmRenderTarget* t = &self->targets[i];
        t->owner = device;
        t->width = self->width;
        t->height = self->height;
        t->is_swapchain_owned = true;
        t->color_state = D3D12_RESOURCE_STATE_PRESENT;
        t->rtv_index = -1;
        t->dsv_index = -1;

        if (FAILED(IDXGISwapChain3_GetBuffer(self->swapchain, (UINT)i,
                &IID_ID3D12Resource, (void**)&t->color_resource))) {
            nm_log(nmLogLevelError, "swapchain", "GetBuffer(%d) failed", i);
            return -1;
        }

        t->rtv_index = nm_alloc_rtv_slot(device);
        if (t->rtv_index < 0) return -1;
        D3D12_CPU_DESCRIPTOR_HANDLE h = nm_rtv_cpu_handle(device, t->rtv_index);
        ID3D12Device_CreateRenderTargetView(device->device, t->color_resource, NULL, h);

        if (create_stencil_for_target(device, t, self->width, self->height) != 0) {
            return -1;
        }
    }
    return 0;
}

void nm_swapchain_release_targets(nmSwapchain* self) {
    nmDevice* device = self->owner;
    for (int i = 0; i < NM_SWAPCHAIN_BUFFER_COUNT; i++) {
        nmRenderTarget* t = &self->targets[i];
        if (t->color_resource)   { ID3D12Resource_Release(t->color_resource);   t->color_resource = NULL; }
        if (t->stencil_resource) { ID3D12Resource_Release(t->stencil_resource); t->stencil_resource = NULL; }
        if (device) {
            nm_free_rtv_slot(device, t->rtv_index);
            nm_free_dsv_slot(device, t->dsv_index);
        }
        t->rtv_index = -1;
        t->dsv_index = -1;
    }
}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmSwapchain* nmCreateSwapchain(const nmDevice* device_const, const nmWindow* window) {
    if (!device_const || !window) return NULL;
    nmDevice* device = (nmDevice*)device_const;  /* doc-declared const, internally mutable */

    nmSwapchain* sc = (nmSwapchain*)calloc(1, sizeof(nmSwapchain));
    if (!sc) {
        nm_log(nmLogLevelError, "swapchain", "out of memory");
        return NULL;
    }
    sc->owner = device;
    sc->hwnd = nm_internal_get_hwnd(window);
    if (!sc->hwnd) {
        nm_log(nmLogLevelError, "swapchain", "could not obtain HWND from window");
        goto fail;
    }
    nmGetFramebufferSize(window, &sc->width, &sc->height);
    if (sc->width <= 0 || sc->height <= 0) {
        /* Treat 0x0 as 1x1 to avoid DXGI failure; will be resized on first WM_SIZE. */
        sc->width = sc->width > 0 ? sc->width : 1;
        sc->height = sc->height > 0 ? sc->height : 1;
    }

    DXGI_SWAP_CHAIN_DESC1 desc;
    memset(&desc, 0, sizeof(desc));
    desc.Width = (UINT)sc->width;
    desc.Height = (UINT)sc->height;
    desc.Format = NM_COLOR_FORMAT;
    desc.Stereo = FALSE;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = NM_SWAPCHAIN_BUFFER_COUNT;
    desc.Scaling = DXGI_SCALING_NONE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    desc.Flags = 0;

    IDXGISwapChain1* sc1 = NULL;
    if (FAILED(IDXGIFactory6_CreateSwapChainForHwnd(device->factory,
            (IUnknown*)device->queue, sc->hwnd, &desc, NULL, NULL, &sc1))) {
        nm_log(nmLogLevelError, "swapchain", "CreateSwapChainForHwnd failed");
        goto fail;
    }
    HRESULT hr = IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void**)&sc->swapchain);
    IDXGISwapChain1_Release(sc1);
    if (FAILED(hr)) {
        nm_log(nmLogLevelError, "swapchain", "QueryInterface(IDXGISwapChain3) failed");
        goto fail;
    }

    IDXGIFactory6_MakeWindowAssociation(device->factory, sc->hwnd, DXGI_MWA_NO_ALT_ENTER);

    if (nm_swapchain_allocate_targets(sc) != 0) goto fail;
    sc->back_index = (int)IDXGISwapChain3_GetCurrentBackBufferIndex(sc->swapchain);

    nm_log(nmLogLevelInfo, "swapchain", "created (%dx%d)", sc->width, sc->height);
    return sc;

fail:
    nmDestroySwapchain(sc);
    return NULL;
}

void nmDestroySwapchain(nmSwapchain* self) {
    if (!self) return;
    if (self->owner) nm_device_wait_idle(self->owner);
    nm_swapchain_release_targets(self);
    if (self->swapchain) {
        IDXGISwapChain3_Release(self->swapchain);
        self->swapchain = NULL;
    }
    free(self);
}

int nmResizeSwapchain(nmSwapchain* self, int width, int height) {
    if (!self || !self->swapchain) return -1;
    if (width <= 0 || height <= 0) return 0;  /* minimized: skip silently */
    if (width == self->width && height == self->height) return 0;

    nm_device_wait_idle(self->owner);
    nm_swapchain_release_targets(self);

    if (FAILED(IDXGISwapChain3_ResizeBuffers(self->swapchain,
            NM_SWAPCHAIN_BUFFER_COUNT, (UINT)width, (UINT)height,
            NM_COLOR_FORMAT, 0))) {
        nm_log(nmLogLevelError, "swapchain", "ResizeBuffers failed (%dx%d)", width, height);
        return -1;
    }
    self->width = width;
    self->height = height;

    if (nm_swapchain_allocate_targets(self) != 0) return -1;
    self->back_index = (int)IDXGISwapChain3_GetCurrentBackBufferIndex(self->swapchain);
    return 0;
}

nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self) {
    if (!self || !self->swapchain) return NULL;
    self->back_index = (int)IDXGISwapChain3_GetCurrentBackBufferIndex(self->swapchain);
    return &self->targets[self->back_index];
}

void nmPresentSwapchain(nmSwapchain* self) {
    if (!self || !self->swapchain) return;
    IDXGISwapChain3_Present(self->swapchain, 1, 0);
    self->back_index = (int)IDXGISwapChain3_GetCurrentBackBufferIndex(self->swapchain);
}

#endif /* _WIN32 */
