/* DX12 command buffer pool: acquire/release with fence-based reuse,
 * begin/end (allocator+list Reset / Close), submit/wait. */

#include "dx12_internal.h"

#ifdef _WIN32

static void wait_for_fence_value(nmDevice* device, UINT64 value) {
    if (ID3D12Fence_GetCompletedValue(device->fence) >= value) return;
    ID3D12Fence_SetEventOnCompletion(device->fence, value, device->fence_event);
    WaitForSingleObject(device->fence_event, INFINITE);
}

nmCommandBuffer* nmAcquireCommandBuffer(nmDevice* device) {
    if (!device) return NULL;

    /* Drain DX12 debug-layer messages opportunistically. */
    nm_drain_info_queue(device);

    for (int i = 0; i < device->cb_pool_count; i++) {
        nmCommandBuffer* cb = &device->cb_pool[i];
        if (cb->in_use) continue;

        /* Wait for previous submission of this slot, if any. */
        if (cb->submitted_fence_value != 0) {
            wait_for_fence_value(device, cb->submitted_fence_value);
        }

        cb->in_use = true;
        cb->recording = false;
        cb->current_rt = NULL;
        cb->current_pipeline = NULL;
        return cb;
    }

    nm_log(nmLogLevelError, "command_buffer",
        "no free command buffer in pool (size %d)", device->cb_pool_count);
    return NULL;
}

void nmReleaseCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;
    self->in_use = false;
}

void nmBeginCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;
    ID3D12CommandAllocator_Reset(self->allocator);
    ID3D12GraphicsCommandList_Reset(self->list, self->allocator, NULL);

    /* The CBV/SRV/UAV and Sampler heaps are device-wide; binding them per CB
     * Begin keeps texture-binding draws working uniformly. */
    ID3D12DescriptorHeap* heaps[2] = {
        self->owner->cbv_srv_uav_heap,
        self->owner->sampler_heap,
    };
    ID3D12GraphicsCommandList_SetDescriptorHeaps(self->list, 2, heaps);

    self->recording = true;
    self->current_rt = NULL;
    self->current_pipeline = NULL;
}

void nmEndCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;

    /* If a swapchain target is currently bound, return it to PRESENT so the
     * subsequent Present succeeds without an explicit transition from the user. */
    if (self->current_rt && self->current_rt->is_swapchain_owned) {
        nm_transition(self, self->current_rt, D3D12_RESOURCE_STATE_PRESENT);
    }

    ID3D12GraphicsCommandList_Close(self->list);
    self->recording = false;
}

void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device) {
    if (!self || !device) return;

    ID3D12CommandList* lists[1] = { (ID3D12CommandList*)self->list };
    ID3D12CommandQueue_ExecuteCommandLists(device->queue, 1, lists);

    self->submitted_fence_value = device->next_fence_value++;
    ID3D12CommandQueue_Signal(device->queue, device->fence, self->submitted_fence_value);
}

void nmWaitForCommandBuffer(nmCommandBuffer* self) {
    if (!self || self->submitted_fence_value == 0) return;
    wait_for_fence_value(self->owner, self->submitted_fence_value);
}

/* ─── Draw ────────────────────────────────────────────────────────────── */

void nmDraw(nmCommandBuffer* self, int vertex_count, int start_vertex) {
    if (!self) return;
    ID3D12GraphicsCommandList_DrawInstanced(self->list,
        (UINT)vertex_count, 1, (UINT)start_vertex, 0);
}

void nmDrawIndexed(nmCommandBuffer* self, int index_count, int start_index, int base_vertex) {
    if (!self) return;
    ID3D12GraphicsCommandList_DrawIndexedInstanced(self->list,
        (UINT)index_count, 1, (UINT)start_index, base_vertex, 0);
}

#endif /* _WIN32 */
