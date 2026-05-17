/* DX12 device implementation: factory, adapter, device, queue, fence,
 * descriptor heaps, command buffer pool. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* ─── Internal helpers ────────────────────────────────────────────────── */

static HRESULT create_heap(nmDevice* dev,
                           ID3D12DescriptorHeap** out,
                           D3D12_DESCRIPTOR_HEAP_TYPE type,
                           UINT count,
                           BOOL shader_visible) {
    D3D12_DESCRIPTOR_HEAP_DESC desc;
    memset(&desc, 0, sizeof(desc));
    desc.Type = type;
    desc.NumDescriptors = count;
    desc.Flags = shader_visible
        ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE
        : D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    desc.NodeMask = 0;
    return ID3D12Device_CreateDescriptorHeap(dev->device, &desc,
        &IID_ID3D12DescriptorHeap, (void**)out);
}

int nm_alloc_rtv_slot(nmDevice* device) {
    if (device->rtv_top == 0) {
        nm_log(nmLogLevelError, "device", "RTV heap exhausted (%d slots)", NM_RTV_HEAP_SIZE);
        return -1;
    }
    return device->rtv_free[--device->rtv_top];
}

void nm_free_rtv_slot(nmDevice* device, int slot) {
    if (slot < 0) return;
    device->rtv_free[device->rtv_top++] = slot;
}

int nm_alloc_dsv_slot(nmDevice* device) {
    if (device->dsv_top == 0) {
        nm_log(nmLogLevelError, "device", "DSV heap exhausted (%d slots)", NM_DSV_HEAP_SIZE);
        return -1;
    }
    return device->dsv_free[--device->dsv_top];
}

void nm_free_dsv_slot(nmDevice* device, int slot) {
    if (slot < 0) return;
    device->dsv_free[device->dsv_top++] = slot;
}

int nm_alloc_srv_slot(nmDevice* device) {
    if (device->srv_top == 0) {
        nm_log(nmLogLevelError, "device",
            "CBV/SRV/UAV heap exhausted (%d slots)", NM_CBV_SRV_UAV_HEAP_SIZE);
        return -1;
    }
    return device->srv_free[--device->srv_top];
}

void nm_free_srv_slot(nmDevice* device, int slot) {
    if (slot < 0) return;
    device->srv_free[device->srv_top++] = slot;
}

D3D12_CPU_DESCRIPTOR_HANDLE nm_rtv_cpu_handle(nmDevice* device, int slot) {
    /* Call via lpVtbl directly: MinGW's COBJMACROS expansion for this
     * aggregate-returning method is intentionally broken to force callers to
     * pick an ABI explicitly. The out-parameter form is portable. */
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    device->rtv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(device->rtv_heap, &h);
    h.ptr += (SIZE_T)slot * device->rtv_descriptor_size;
    return h;
}

D3D12_CPU_DESCRIPTOR_HANDLE nm_dsv_cpu_handle(nmDevice* device, int slot) {
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    device->dsv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(device->dsv_heap, &h);
    h.ptr += (SIZE_T)slot * device->dsv_descriptor_size;
    return h;
}

D3D12_CPU_DESCRIPTOR_HANDLE nm_srv_cpu_handle(nmDevice* device, int slot) {
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    device->cbv_srv_uav_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(device->cbv_srv_uav_heap, &h);
    h.ptr += (SIZE_T)slot * device->cbv_srv_uav_descriptor_size;
    return h;
}

D3D12_GPU_DESCRIPTOR_HANDLE nm_srv_gpu_handle(nmDevice* device, int slot) {
    D3D12_GPU_DESCRIPTOR_HANDLE h;
    device->cbv_srv_uav_heap->lpVtbl->GetGPUDescriptorHandleForHeapStart(device->cbv_srv_uav_heap, &h);
    h.ptr += (UINT64)slot * device->cbv_srv_uav_descriptor_size;
    return h;
}

void nm_device_wait_idle(nmDevice* device) {
    if (!device || !device->queue || !device->fence) return;
    UINT64 v = device->next_fence_value++;
    ID3D12CommandQueue_Signal(device->queue, device->fence, v);
    if (ID3D12Fence_GetCompletedValue(device->fence) < v) {
        ID3D12Fence_SetEventOnCompletion(device->fence, v, device->fence_event);
        WaitForSingleObject(device->fence_event, INFINITE);
    }
}

void nm_drain_info_queue(nmDevice* device) {
    if (!device || !device->info_queue) return;
    UINT64 n = ID3D12InfoQueue_GetNumStoredMessages(device->info_queue);
    for (UINT64 i = 0; i < n; i++) {
        SIZE_T size = 0;
        ID3D12InfoQueue_GetMessage(device->info_queue, i, NULL, &size);
        if (size == 0) continue;
        D3D12_MESSAGE* msg = (D3D12_MESSAGE*)malloc(size);
        if (!msg) continue;
        if (SUCCEEDED(ID3D12InfoQueue_GetMessage(device->info_queue, i, msg, &size))) {
            nmLogLevel lvl = nmLogLevelInfo;
            switch (msg->Severity) {
                case D3D12_MESSAGE_SEVERITY_CORRUPTION:
                case D3D12_MESSAGE_SEVERITY_ERROR:   lvl = nmLogLevelError; break;
                case D3D12_MESSAGE_SEVERITY_WARNING: lvl = nmLogLevelWarn;  break;
                case D3D12_MESSAGE_SEVERITY_INFO:    lvl = nmLogLevelInfo;  break;
                case D3D12_MESSAGE_SEVERITY_MESSAGE: lvl = nmLogLevelDebug; break;
            }
            nm_log(lvl, "dx12", "%s", msg->pDescription);
        }
        free(msg);
    }
    ID3D12InfoQueue_ClearStoredMessages(device->info_queue);
}

static int pick_adapter_and_create_device(nmDevice* dev) {
    UINT idx = 0;
    while (1) {
        HRESULT hr = IDXGIFactory6_EnumAdapterByGpuPreference(
            dev->factory, idx++,
            DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
            &IID_IDXGIAdapter1, (void**)&dev->adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) {
            nm_log(nmLogLevelError, "dx12", "no suitable adapter found");
            return -1;
        }
        if (FAILED(hr)) {
            nm_log(nmLogLevelError, "dx12", "EnumAdapterByGpuPreference failed (hr=0x%08lx)", (unsigned long)hr);
            return -1;
        }

        DXGI_ADAPTER_DESC1 desc;
        IDXGIAdapter1_GetDesc1(dev->adapter, &desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
            IDXGIAdapter1_Release(dev->adapter);
            dev->adapter = NULL;
            continue;
        }

        if (SUCCEEDED(D3D12CreateDevice((IUnknown*)dev->adapter,
                D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device,
                (void**)&dev->device))) {
            char name[256];
            WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1,
                                name, (int)sizeof(name), NULL, NULL);
            nm_log(nmLogLevelInfo, "dx12", "device created (adapter: %s)", name);
            return 0;
        }

        IDXGIAdapter1_Release(dev->adapter);
        dev->adapter = NULL;
    }
}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmDevice* nmCreateDevice(void) {
    nmDevice* dev = (nmDevice*)calloc(1, sizeof(nmDevice));
    if (!dev) {
        nm_log(nmLogLevelError, "device", "out of memory");
        return NULL;
    }

    /* 1. Debug layer (best effort, never fatal). */
#ifdef NM_DX12_DEBUG
    {
        ID3D12Debug* debug = NULL;
        if (SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, (void**)&debug))) {
            ID3D12Debug_EnableDebugLayer(debug);
            ID3D12Debug_Release(debug);
            nm_log(nmLogLevelInfo, "dx12", "debug layer enabled");
        } else {
            nm_log(nmLogLevelWarn, "dx12",
                "debug layer unavailable (install \"Graphics Tools\" to enable)");
        }
    }
#endif

    /* 2. DXGI Factory. */
    UINT factory_flags = 0;
#ifdef NM_DX12_DEBUG
    factory_flags |= DXGI_CREATE_FACTORY_DEBUG;
#endif
    if (FAILED(CreateDXGIFactory2(factory_flags,
            &IID_IDXGIFactory6, (void**)&dev->factory))) {
        nm_log(nmLogLevelError, "dx12", "CreateDXGIFactory2 failed");
        goto fail;
    }

    /* 3. Adapter + device. */
    if (pick_adapter_and_create_device(dev) != 0) goto fail;

    /* 4. InfoQueue (debug only). */
#ifdef NM_DX12_DEBUG
    if (SUCCEEDED(ID3D12Device_QueryInterface(dev->device,
            &IID_ID3D12InfoQueue, (void**)&dev->info_queue))) {
        ID3D12InfoQueue_SetBreakOnSeverity(dev->info_queue,
            D3D12_MESSAGE_SEVERITY_CORRUPTION, TRUE);
        ID3D12InfoQueue_SetBreakOnSeverity(dev->info_queue,
            D3D12_MESSAGE_SEVERITY_ERROR, TRUE);
    }
#endif

    /* 5. Command queue. */
    {
        D3D12_COMMAND_QUEUE_DESC qd;
        memset(&qd, 0, sizeof(qd));
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        qd.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
        if (FAILED(ID3D12Device_CreateCommandQueue(dev->device, &qd,
                &IID_ID3D12CommandQueue, (void**)&dev->queue))) {
            nm_log(nmLogLevelError, "dx12", "CreateCommandQueue failed");
            goto fail;
        }
    }

    /* 6. Fence + event. */
    if (FAILED(ID3D12Device_CreateFence(dev->device, 0, D3D12_FENCE_FLAG_NONE,
            &IID_ID3D12Fence, (void**)&dev->fence))) {
        nm_log(nmLogLevelError, "dx12", "CreateFence failed");
        goto fail;
    }
    dev->fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!dev->fence_event) {
        nm_log(nmLogLevelError, "dx12", "CreateEventW failed");
        goto fail;
    }
    dev->next_fence_value = 1;

    /* 7. Descriptor heaps. */
    if (FAILED(create_heap(dev, &dev->cbv_srv_uav_heap,
            D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
            NM_CBV_SRV_UAV_HEAP_SIZE, TRUE))) {
        nm_log(nmLogLevelError, "dx12", "CreateDescriptorHeap(CBV_SRV_UAV) failed");
        goto fail;
    }
    if (FAILED(create_heap(dev, &dev->sampler_heap,
            D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
            NM_SAMPLER_HEAP_SIZE, TRUE))) {
        nm_log(nmLogLevelError, "dx12", "CreateDescriptorHeap(SAMPLER) failed");
        goto fail;
    }
    if (FAILED(create_heap(dev, &dev->rtv_heap,
            D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
            NM_RTV_HEAP_SIZE, FALSE))) {
        nm_log(nmLogLevelError, "dx12", "CreateDescriptorHeap(RTV) failed");
        goto fail;
    }
    if (FAILED(create_heap(dev, &dev->dsv_heap,
            D3D12_DESCRIPTOR_HEAP_TYPE_DSV,
            NM_DSV_HEAP_SIZE, FALSE))) {
        nm_log(nmLogLevelError, "dx12", "CreateDescriptorHeap(DSV) failed");
        goto fail;
    }
    dev->rtv_descriptor_size = ID3D12Device_GetDescriptorHandleIncrementSize(
        dev->device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    dev->dsv_descriptor_size = ID3D12Device_GetDescriptorHandleIncrementSize(
        dev->device, D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    dev->cbv_srv_uav_descriptor_size = ID3D12Device_GetDescriptorHandleIncrementSize(
        dev->device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

    /* 8. RTV / DSV / SRV free stacks (alloc returns 0, 1, 2, ... in order). */
    dev->rtv_top = NM_RTV_HEAP_SIZE;
    for (int i = 0; i < NM_RTV_HEAP_SIZE; i++) {
        dev->rtv_free[i] = NM_RTV_HEAP_SIZE - 1 - i;
    }
    dev->dsv_top = NM_DSV_HEAP_SIZE;
    for (int i = 0; i < NM_DSV_HEAP_SIZE; i++) {
        dev->dsv_free[i] = NM_DSV_HEAP_SIZE - 1 - i;
    }
    dev->srv_top = NM_CBV_SRV_UAV_HEAP_SIZE;
    for (int i = 0; i < NM_CBV_SRV_UAV_HEAP_SIZE; i++) {
        dev->srv_free[i] = NM_CBV_SRV_UAV_HEAP_SIZE - 1 - i;
    }

    /* 9. Command buffer pool (N=1 for stage 1). */
    for (int i = 0; i < NM_CB_POOL_SIZE; i++) {
        nmCommandBuffer* cb = &dev->cb_pool[i];
        cb->owner = dev;
        cb->in_use = 0;
        cb->recording = 0;
        cb->current_rt = NULL;
        cb->submitted_fence_value = 0;
        if (FAILED(ID3D12Device_CreateCommandAllocator(dev->device,
                D3D12_COMMAND_LIST_TYPE_DIRECT,
                &IID_ID3D12CommandAllocator, (void**)&cb->allocator))) {
            nm_log(nmLogLevelError, "dx12", "CreateCommandAllocator failed");
            goto fail;
        }
        if (FAILED(ID3D12Device_CreateCommandList(dev->device, 0,
                D3D12_COMMAND_LIST_TYPE_DIRECT, cb->allocator, NULL,
                &IID_ID3D12GraphicsCommandList, (void**)&cb->list))) {
            nm_log(nmLogLevelError, "dx12", "CreateCommandList failed");
            goto fail;
        }
        /* Lists start in the recording state; close so Begin can Reset cleanly. */
        ID3D12GraphicsCommandList_Close(cb->list);
    }
    dev->cb_pool_count = NM_CB_POOL_SIZE;

    nm_log(nmLogLevelInfo, "device", "device initialized");
    return dev;

fail:
    nmDestroyDevice(dev);
    return NULL;
}

void nmDestroyDevice(nmDevice* self) {
    if (!self) return;

    if (self->fence && self->queue) {
        nm_device_wait_idle(self);
    }

    for (int i = 0; i < self->cb_pool_count; i++) {
        nmCommandBuffer* cb = &self->cb_pool[i];
        if (cb->list)      { ID3D12GraphicsCommandList_Release(cb->list); cb->list = NULL; }
        if (cb->allocator) { ID3D12CommandAllocator_Release(cb->allocator); cb->allocator = NULL; }
    }
    self->cb_pool_count = 0;

    if (self->cbv_srv_uav_heap) { ID3D12DescriptorHeap_Release(self->cbv_srv_uav_heap); self->cbv_srv_uav_heap = NULL; }
    if (self->sampler_heap)     { ID3D12DescriptorHeap_Release(self->sampler_heap);     self->sampler_heap = NULL; }
    if (self->rtv_heap)         { ID3D12DescriptorHeap_Release(self->rtv_heap);         self->rtv_heap = NULL; }
    if (self->dsv_heap)         { ID3D12DescriptorHeap_Release(self->dsv_heap);         self->dsv_heap = NULL; }

    if (self->fence_event) { CloseHandle(self->fence_event); self->fence_event = NULL; }
    if (self->fence)       { ID3D12Fence_Release(self->fence); self->fence = NULL; }
    if (self->queue)       { ID3D12CommandQueue_Release(self->queue); self->queue = NULL; }
    if (self->info_queue)  { ID3D12InfoQueue_Release(self->info_queue); self->info_queue = NULL; }
    if (self->device)      { ID3D12Device_Release(self->device); self->device = NULL; }
    if (self->adapter)     { IDXGIAdapter1_Release(self->adapter); self->adapter = NULL; }
    if (self->factory)     { IDXGIFactory6_Release(self->factory); self->factory = NULL; }

    free(self);
}

#endif /* _WIN32 */
