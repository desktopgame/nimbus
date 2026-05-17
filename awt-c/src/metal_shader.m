/* Metal shader: MSL source -> MTLLibrary -> MTLFunction. Entry names are
 * fixed by the awt-c contract: vsMain for vertex, psMain for fragment. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

nmShader* nmCompileShader(nmShaderStage stage, const char* source) {
    if (!source) return NULL;

    const char* entry;
    switch (stage) {
        case nmShaderStageVertex: entry = "vsMain"; break;
        case nmShaderStagePixel:  entry = "psMain"; break;
        default:
            nm_log(nmLogLevelError, "shader", "unsupported stage %d", (int)stage);
            return NULL;
    }

    nmShader* sh = (nmShader*)calloc(1, sizeof(nmShader));
    if (!sh) return NULL;
    sh->stage = stage;

    @autoreleasepool {
        /* The device used here is the system default — we don't have an
         * nmDevice argument by contract, mirroring nmCompileShader's DX12
         * implementation which uses D3DCompile (device-free). */
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            nm_log(nmLogLevelError, "shader", "MTLCreateSystemDefaultDevice failed");
            free(sh);
            return NULL;
        }

        NSString* src = [[NSString alloc] initWithUTF8String:source];
        NSError* err = nil;
        MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
        [opts release];
        [src release];

        if (!lib) {
            const char* msg = err ? [[err localizedDescription] UTF8String] : "(no message)";
            nm_log(nmLogLevelError, "shader", "newLibraryWithSource (%s): %s", entry, msg);
            [device release];
            free(sh);
            return NULL;
        }
        if (err) {
            /* Warnings without an error still surface via the NSError. */
            const char* msg = [[err localizedDescription] UTF8String];
            nm_log(nmLogLevelWarn, "shader", "newLibraryWithSource (%s): %s", entry, msg);
        }

        NSString* entry_ns = [NSString stringWithUTF8String:entry];
        id<MTLFunction> fn = [lib newFunctionWithName:entry_ns];
        if (!fn) {
            nm_log(nmLogLevelError, "shader", "newFunctionWithName: '%s' not found", entry);
            [lib release];
            [device release];
            free(sh);
            return NULL;
        }
        sh->library = [lib retain];
        sh->function = [fn retain];
        [fn release];
        [lib release];
        [device release];
    }

    return sh;
}

nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size) {
    (void)stage; (void)binary; (void)size;
    nm_log(nmLogLevelError, "shader", "nmLoadShader: precompiled bytecode not supported in Metal backend");
    return NULL;
}

void nmDestroyShader(nmShader* self) {
    if (!self) return;
    if (self->function) [self->function release];
    if (self->library)  [self->library release];
    free(self);
}

#endif /* __APPLE__ */
