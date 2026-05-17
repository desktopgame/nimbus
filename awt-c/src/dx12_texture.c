/* DX12 texture: DEFAULT-heap resource + persistent UPLOAD staging,
 * SRV in the device CBV/SRV/UAV heap. Auto state-tracked. */

#include "dx12_internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

static DXGI_FORMAT dxgi_format(nmTextureFormat f) {
    switch (f) {
        case nmTextureFormatRGBA8: return DXGI_FORMAT_R8G8B8A8_UNORM;
        case nmTextureFormatBGRA8: return DXGI_FORMAT_B8G8R8A8_UNORM;
        case nmTextureFormatR8:    return DXGI_FORMAT_R8_UNORM;
    }
    return DXGI_FORMAT_UNKNOWN;
}

static UINT bytes_per_pixel(nmTextureFormat f) {
    switch (f) {
        case nmTextureFormatRGBA8: return 4;
        case nmTextureFormatBGRA8: return 4;
        case nmTextureFormatR8:    return 1;
    }
    return 0;
}

/* D3D12 requires upload-buffer row pitch aligned to 256 bytes. */
static UINT aligned_row_pitch(UINT width, UINT bpp) {
    UINT raw = width * bpp;
    return (raw + 255u) & ~255u;
}

nmTexture* nmCreateTexture(nmDevice* device, int width, int height, nmTextureFormat format) {
    if (!device || width <= 0 || height <= 0) return NULL;
    UINT bpp = bytes_per_pixel(format);
    DXGI_FORMAT fmt = dxgi_format(format);
    if (bpp == 0 || fmt == DXGI_FORMAT_UNKNOWN) {
        nm_log(nmLogLevelError, "texture", "unsupported format %d", (int)format);
        return NULL;
    }

    nmTexture* t = (nmTexture*)calloc(1, sizeof(nmTexture));
    if (!t) return NULL;
    t->owner = device;
    t->width = width;
    t->height = height;
    t->format = format;
    t->bytes_per_pixel = bpp;
    t->srv_index = -1;
    t->state = D3D12_RESOURCE_STATE_COPY_DEST;

    /* DEFAULT-heap texture resource. */
    D3D12_HEAP_PROPERTIES hp_default;
    memset(&hp_default, 0, sizeof(hp_default));
    hp_default.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC rd;
    memset(&rd, 0, sizeof(rd));
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Alignment = 0;
    rd.Width = (UINT64)width;
    rd.Height = (UINT)height;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = fmt;
    rd.SampleDesc.Count = 1;
    rd.SampleDesc.Quality = 0;
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_NONE;

    if (FAILED(ID3D12Device_CreateCommittedResource(device->device, &hp_default,
            D3D12_HEAP_FLAG_NONE, &rd, t->state, NULL,
            &IID_ID3D12Resource, (void**)&t->resource))) {
        nm_log(nmLogLevelError, "texture", "CreateCommittedResource(DEFAULT) failed");
        free(t);
        return NULL;
    }

    /* Persistent UPLOAD-heap staging sized for the whole texture. */
    UINT row_pitch = aligned_row_pitch((UINT)width, bpp);
    UINT64 upload_size = (UINT64)row_pitch * (UINT64)height;

    D3D12_HEAP_PROPERTIES hp_upload;
    memset(&hp_upload, 0, sizeof(hp_upload));
    hp_upload.Type = D3D12_HEAP_TYPE_UPLOAD;

    D3D12_RESOURCE_DESC ud;
    memset(&ud, 0, sizeof(ud));
    ud.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    ud.Width = upload_size;
    ud.Height = 1;
    ud.DepthOrArraySize = 1;
    ud.MipLevels = 1;
    ud.Format = DXGI_FORMAT_UNKNOWN;
    ud.SampleDesc.Count = 1;
    ud.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ud.Flags = D3D12_RESOURCE_FLAG_NONE;

    if (FAILED(ID3D12Device_CreateCommittedResource(device->device, &hp_upload,
            D3D12_HEAP_FLAG_NONE, &ud,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
            &IID_ID3D12Resource, (void**)&t->upload))) {
        nm_log(nmLogLevelError, "texture", "CreateCommittedResource(UPLOAD) failed");
        ID3D12Resource_Release(t->resource);
        free(t);
        return NULL;
    }

    /* Allocate SRV slot + write descriptor. */
    t->srv_index = nm_alloc_srv_slot(device);
    if (t->srv_index < 0) {
        ID3D12Resource_Release(t->upload);
        ID3D12Resource_Release(t->resource);
        free(t);
        return NULL;
    }
    D3D12_SHADER_RESOURCE_VIEW_DESC srv;
    memset(&srv, 0, sizeof(srv));
    srv.Format = fmt;
    srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.Texture2D.MipLevels = 1;
    srv.Texture2D.MostDetailedMip = 0;
    srv.Texture2D.PlaneSlice = 0;
    srv.Texture2D.ResourceMinLODClamp = 0.0f;

    D3D12_CPU_DESCRIPTOR_HANDLE cpu = nm_srv_cpu_handle(device, t->srv_index);
    ID3D12Device_CreateShaderResourceView(device->device, t->resource, &srv, cpu);

    return t;
}

void nmDestroyTexture(nmTexture* self) {
    if (!self) return;
    if (self->srv_index >= 0) nm_free_srv_slot(self->owner, self->srv_index);
    if (self->upload) ID3D12Resource_Release(self->upload);
    if (self->resource) ID3D12Resource_Release(self->resource);
    free(self);
}

/* Copy tightly-packed CPU data to the UPLOAD heap staging buffer, accounting for
 * D3D12's row-pitch alignment. */
static void stage_region(nmTexture* self, int x, int y, int w, int h,
                         const void* data, size_t src_row_pitch) {
    UINT dst_pitch = aligned_row_pitch((UINT)self->width, self->bytes_per_pixel);

    void* mapped = NULL;
    D3D12_RANGE read_range = { 0, 0 };
    if (FAILED(ID3D12Resource_Map(self->upload, 0, &read_range, &mapped))) {
        nm_log(nmLogLevelError, "texture", "upload Map failed");
        return;
    }

    uint8_t* dst = (uint8_t*)mapped
        + (size_t)y * dst_pitch
        + (size_t)x * self->bytes_per_pixel;
    const uint8_t* src = (const uint8_t*)data;
    size_t row_bytes = (size_t)w * self->bytes_per_pixel;

    for (int row = 0; row < h; row++) {
        memcpy(dst + (size_t)row * dst_pitch,
               src + (size_t)row * src_row_pitch,
               row_bytes);
    }

    ID3D12Resource_Unmap(self->upload, 0, NULL);
}

/* Issue a one-shot copy from upload staging into the texture, synchronously. */
static void flush_to_texture(nmTexture* self) {
    nmDevice* dev = self->owner;
    ID3D12CommandAllocator* alloc = NULL;
    ID3D12GraphicsCommandList* list = NULL;

    if (FAILED(ID3D12Device_CreateCommandAllocator(dev->device,
            D3D12_COMMAND_LIST_TYPE_DIRECT,
            &IID_ID3D12CommandAllocator, (void**)&alloc))) {
        nm_log(nmLogLevelError, "texture", "upload CreateCommandAllocator failed");
        return;
    }
    if (FAILED(ID3D12Device_CreateCommandList(dev->device, 0,
            D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL,
            &IID_ID3D12GraphicsCommandList, (void**)&list))) {
        nm_log(nmLogLevelError, "texture", "upload CreateCommandList failed");
        ID3D12CommandAllocator_Release(alloc);
        return;
    }

    /* Transition to COPY_DEST if needed. */
    if (self->state != D3D12_RESOURCE_STATE_COPY_DEST) {
        D3D12_RESOURCE_BARRIER b;
        memset(&b, 0, sizeof(b));
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
        b.Transition.pResource = self->resource;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = self->state;
        b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_DEST;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
        self->state = D3D12_RESOURCE_STATE_COPY_DEST;
    }

    /* Copy from upload buffer to texture. */
    D3D12_TEXTURE_COPY_LOCATION dst;
    memset(&dst, 0, sizeof(dst));
    dst.pResource = self->resource;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.SubresourceIndex = 0;

    D3D12_TEXTURE_COPY_LOCATION src;
    memset(&src, 0, sizeof(src));
    src.pResource = self->upload;
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint.Offset = 0;
    src.PlacedFootprint.Footprint.Format = dxgi_format(self->format);
    src.PlacedFootprint.Footprint.Width = (UINT)self->width;
    src.PlacedFootprint.Footprint.Height = (UINT)self->height;
    src.PlacedFootprint.Footprint.Depth = 1;
    src.PlacedFootprint.Footprint.RowPitch = aligned_row_pitch((UINT)self->width, self->bytes_per_pixel);

    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);

    /* Transition to PIXEL_SHADER_RESOURCE for sampling. */
    {
        D3D12_RESOURCE_BARRIER b;
        memset(&b, 0, sizeof(b));
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
        b.Transition.pResource = self->resource;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
        b.Transition.StateAfter = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
        self->state = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    }

    ID3D12GraphicsCommandList_Close(list);
    ID3D12CommandList* lists[1] = { (ID3D12CommandList*)list };
    ID3D12CommandQueue_ExecuteCommandLists(dev->queue, 1, lists);

    /* Synchronous: wait for the copy to complete before returning. */
    nm_device_wait_idle(dev);

    ID3D12GraphicsCommandList_Release(list);
    ID3D12CommandAllocator_Release(alloc);
}

void nmUploadTexture(nmTexture* self, const void* data, size_t size) {
    if (!self || !data) return;
    size_t expected = (size_t)self->width * (size_t)self->height * self->bytes_per_pixel;
    if (size < expected) {
        nm_log(nmLogLevelError, "texture",
            "nmUploadTexture: size %zu < expected %zu", size, expected);
        return;
    }
    stage_region(self, 0, 0, self->width, self->height,
                 data, (size_t)self->width * self->bytes_per_pixel);
    flush_to_texture(self);
}

void nmUploadTextureRegion(nmTexture* self, int x, int y, int w, int h,
                           const void* data, size_t row_pitch) {
    if (!self || !data) return;
    if (x < 0 || y < 0 || w <= 0 || h <= 0
            || x + w > self->width || y + h > self->height) {
        nm_log(nmLogLevelError, "texture",
            "nmUploadTextureRegion: out of bounds (%d,%d %dx%d in %dx%d)",
            x, y, w, h, self->width, self->height);
        return;
    }
    stage_region(self, x, y, w, h, data, row_pitch);
    flush_to_texture(self);
}

void nmBindTexture(nmCommandBuffer* self, nmTexture* texture, int slot) {
    if (!self || !texture || !self->current_pipeline) return;
    nmRootSignature* sig = self->current_pipeline->root_signature;
    if (!sig) return;

    for (int i = 0; i < sig->param_count; i++) {
        if (sig->params[i].type == nmRootBindingTypeTexture
                && sig->params[i].slot == slot) {
            D3D12_GPU_DESCRIPTOR_HANDLE h = nm_srv_gpu_handle(
                self->owner, texture->srv_index);
            ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(
                self->list, (UINT)sig->params[i].root_param_index, h);
            return;
        }
    }
    nm_log(nmLogLevelWarn, "texture",
        "nmBindTexture: no Texture binding for slot %d in current pipeline", slot);
}

#endif /* _WIN32 */
