#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>

#include <drm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

struct dumb_buffer {
    uint32_t handle;
    uint32_t pitch;
    uint64_t size;
    uint32_t fb_id;
    uint32_t *map;
};

struct flip_state {
    volatile int waiting;
    uint64_t count;
};

static volatile sig_atomic_t stop_requested;

static void on_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static double monotonic_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static const char *connector_type_name(uint32_t type)
{
    switch (type) {
    case DRM_MODE_CONNECTOR_HDMIA:
        return "HDMI-A";
    case DRM_MODE_CONNECTOR_HDMIB:
        return "HDMI-B";
    case DRM_MODE_CONNECTOR_DisplayPort:
        return "DP";
    case DRM_MODE_CONNECTOR_DVID:
        return "DVI-D";
    case DRM_MODE_CONNECTOR_DVII:
        return "DVI-I";
    case DRM_MODE_CONNECTOR_eDP:
        return "eDP";
    default:
        return "connector";
    }
}

static int create_dumb_buffer(int fd, uint32_t width, uint32_t height,
                              struct dumb_buffer *buffer)
{
    struct drm_mode_create_dumb create = {0};
    struct drm_mode_map_dumb map = {0};

    create.width = width;
    create.height = height;
    create.bpp = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) < 0) {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        return -1;
    }

    buffer->handle = create.handle;
    buffer->pitch = create.pitch;
    buffer->size = create.size;

    if (drmModeAddFB(fd, width, height, 24, 32, buffer->pitch,
                     buffer->handle, &buffer->fb_id) != 0) {
        perror("drmModeAddFB");
        return -1;
    }

    map.handle = buffer->handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map) < 0) {
        perror("DRM_IOCTL_MODE_MAP_DUMB");
        return -1;
    }

    buffer->map = mmap(NULL, buffer->size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, map.offset);
    if (buffer->map == MAP_FAILED) {
        buffer->map = NULL;
        perror("mmap dumb buffer");
        return -1;
    }
    return 0;
}

static void destroy_dumb_buffer(int fd, struct dumb_buffer *buffer)
{
    struct drm_mode_destroy_dumb destroy = {0};

    if (buffer->map)
        munmap(buffer->map, buffer->size);
    if (buffer->fb_id)
        drmModeRmFB(fd, buffer->fb_id);
    if (buffer->handle) {
        destroy.handle = buffer->handle;
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
    memset(buffer, 0, sizeof(*buffer));
}

static void fill_test_pattern(struct dumb_buffer *buffer, uint32_t width,
                              uint32_t height, unsigned frame)
{
    static const uint32_t bars[] = {
        0x00ffffff, 0x00ffff00, 0x0000ffff, 0x0000ff00,
        0x00ff00ff, 0x00ff0000, 0x000000ff, 0x00101010,
    };
    uint32_t stride = buffer->pitch / sizeof(uint32_t);
    uint32_t marker_x = (frame * 31U) % width;
    uint32_t y;

    for (y = 0; y < height; ++y) {
        uint32_t *row = buffer->map + y * stride;
        uint32_t x;

        for (x = 0; x < width; ++x) {
            uint32_t colour = bars[(x * 8U) / width];
            if (y < 56U)
                colour = ((frame / 10U) & 1U) ? 0x000060d0 : 0x0000b050;
            if (x >= marker_x && x < marker_x + 20U)
                colour = 0x00ffffff;
            row[x] = colour;
        }
    }
}

static void page_flip_handler(int fd, unsigned int frame,
                              unsigned int sec, unsigned int usec,
                              void *data)
{
    struct flip_state *state = data;
    (void)fd;
    (void)frame;
    (void)sec;
    (void)usec;
    state->waiting = 0;
    state->count++;
}

static uint32_t choose_crtc(int fd, const drmModeRes *resources,
                            const drmModeConnector *connector)
{
    int i;

    if (connector->encoder_id) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, connector->encoder_id);
        if (encoder) {
            uint32_t crtc_id = encoder->crtc_id;
            drmModeFreeEncoder(encoder);
            if (crtc_id)
                return crtc_id;
        }
    }

    for (i = 0; i < connector->count_encoders; ++i) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, connector->encoders[i]);
        int j;
        if (!encoder)
            continue;
        for (j = 0; j < resources->count_crtcs; ++j) {
            if (encoder->possible_crtcs & (1U << j)) {
                uint32_t crtc_id = resources->crtcs[j];
                drmModeFreeEncoder(encoder);
                return crtc_id;
            }
        }
        drmModeFreeEncoder(encoder);
    }
    return 0;
}

static int choose_mode(const drmModeConnector *connector)
{
    int preferred = -1;
    int best = 0;
    int i;

    for (i = 0; i < connector->count_modes; ++i) {
        const drmModeModeInfo *mode = &connector->modes[i];
        if (mode->type & DRM_MODE_TYPE_PREFERRED)
            preferred = i;
        if ((uint64_t)mode->hdisplay * mode->vdisplay >
            (uint64_t)connector->modes[best].hdisplay *
                connector->modes[best].vdisplay)
            best = i;
    }
    return preferred >= 0 ? preferred : best;
}

int main(int argc, char **argv)
{
    const char *device = argc > 1 ? argv[1] : "/dev/dri/card0";
    int duration = argc > 2 ? atoi(argv[2]) : 60;
    int fd = -1, result = EXIT_FAILURE, master = 0;
    drmModeRes *resources = NULL;
    drmModeConnector *connector = NULL;
    drmModeCrtc *saved_crtc = NULL;
    drmModeModeInfo mode;
    uint32_t connector_id = 0, crtc_id = 0;
    struct dumb_buffer buffers[2] = {{0}};
    struct flip_state flip = {0};
    drmEventContext event = {0};
    double start, next_flip, end;
    unsigned current = 0, frame = 0;
    int i;
    Dl_info info = {0};

    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    if (duration < 1)
        duration = 1;

    if (dladdr((void *)(uintptr_t)&drmModeGetResources, &info) && info.dli_fname)
        printf("libdrm_path=%s\n", info.dli_fname);

    fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror(device);
        goto out;
    }
    printf("device=%s\n", device);

    if (drmSetMaster(fd) == 0) {
        master = 1;
        puts("drm_master=acquired");
    } else if (errno == EINVAL) {
        master = 1;
        puts("drm_master=already-master");
    } else {
        perror("drmSetMaster");
        goto out;
    }

    resources = drmModeGetResources(fd);
    if (!resources) {
        perror("drmModeGetResources");
        goto out;
    }

    for (i = 0; i < resources->count_connectors; ++i) {
        drmModeConnector *candidate =
            drmModeGetConnector(fd, resources->connectors[i]);
        if (!candidate)
            continue;
        if (candidate->connection == DRM_MODE_CONNECTED &&
            candidate->count_modes > 0) {
            connector = candidate;
            break;
        }
        drmModeFreeConnector(candidate);
    }
    if (!connector) {
        fputs("no connected connector with a mode\n", stderr);
        goto out;
    }

    connector_id = connector->connector_id;
    i = choose_mode(connector);
    mode = connector->modes[i];
    crtc_id = choose_crtc(fd, resources, connector);
    if (!crtc_id) {
        fputs("no usable CRTC\n", stderr);
        goto out;
    }
    printf("connector=%s-%u id=%u\n",
           connector_type_name(connector->connector_type),
           connector->connector_type_id, connector_id);
    printf("mode=%s %ux%u clock=%u\n", mode.name, mode.hdisplay,
           mode.vdisplay, mode.clock);
    printf("crtc_id=%u duration_seconds=%d\n", crtc_id, duration);

    saved_crtc = drmModeGetCrtc(fd, crtc_id);
    if (!saved_crtc) {
        perror("drmModeGetCrtc");
        goto out;
    }

    if (create_dumb_buffer(fd, mode.hdisplay, mode.vdisplay, &buffers[0]) ||
        create_dumb_buffer(fd, mode.hdisplay, mode.vdisplay, &buffers[1]))
        goto out;
    fill_test_pattern(&buffers[0], mode.hdisplay, mode.vdisplay, 0);
    fill_test_pattern(&buffers[1], mode.hdisplay, mode.vdisplay, 1);

    if (drmModeSetCrtc(fd, crtc_id, buffers[0].fb_id, 0, 0,
                       &connector_id, 1, &mode) != 0) {
        perror("drmModeSetCrtc");
        goto out;
    }
    printf("scanout=active framebuffer=%u\n", buffers[0].fb_id);

    event.version = DRM_EVENT_CONTEXT_VERSION;
    event.page_flip_handler = page_flip_handler;
    start = monotonic_seconds();
    end = start + duration;
    next_flip = start;

    while (!stop_requested && monotonic_seconds() < end) {
        unsigned next = current ^ 1U;
        double now;

        fill_test_pattern(&buffers[next], mode.hdisplay, mode.vdisplay, frame++);
        flip.waiting = 1;
        if (drmModePageFlip(fd, crtc_id, buffers[next].fb_id,
                            DRM_MODE_PAGE_FLIP_EVENT, &flip) != 0) {
            perror("drmModePageFlip");
            goto restore;
        }
        while (flip.waiting && !stop_requested) {
            fd_set fds;
            struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
            int ready;
            FD_ZERO(&fds);
            FD_SET(fd, &fds);
            ready = select(fd + 1, &fds, NULL, NULL, &timeout);
            if (ready < 0 && errno == EINTR)
                continue;
            if (ready <= 0) {
                fputs("page-flip event timeout\n", stderr);
                goto restore;
            }
            if (drmHandleEvent(fd, &event) != 0) {
                perror("drmHandleEvent");
                goto restore;
            }
        }
        current = next;
        next_flip += 0.1;
        now = monotonic_seconds();
        if (next_flip > now) {
            struct timespec delay;
            double seconds = next_flip - now;
            delay.tv_sec = (time_t)seconds;
            delay.tv_nsec = (long)((seconds - delay.tv_sec) * 1000000000.0);
            nanosleep(&delay, NULL);
        }
        if (flip.count && flip.count % 100 == 0)
            printf("progress_seconds=%.1f page_flips=%" PRIu64 "\n",
                   monotonic_seconds() - start, flip.count);
    }

    printf("elapsed_seconds=%.3f\n", monotonic_seconds() - start);
    printf("page_flips=%" PRIu64 "\n", flip.count);
    if (!stop_requested && monotonic_seconds() - start >= duration - 0.05 &&
        flip.count >= (uint64_t)duration * 8U) {
        puts("PASS: KMS scanout and page flips completed");
        result = EXIT_SUCCESS;
    }

restore:
    if (saved_crtc && saved_crtc->mode_valid && saved_crtc->buffer_id) {
        if (drmModeSetCrtc(fd, saved_crtc->crtc_id, saved_crtc->buffer_id,
                           saved_crtc->x, saved_crtc->y, &connector_id, 1,
                           &saved_crtc->mode) == 0)
            puts("original_crtc=restored");
        else
            perror("restore drmModeSetCrtc");
    } else if (crtc_id) {
        drmModeSetCrtc(fd, crtc_id, 0, 0, 0, NULL, 0, NULL);
        puts("original_crtc=disabled-for-display-manager");
    }

out:
    destroy_dumb_buffer(fd, &buffers[1]);
    destroy_dumb_buffer(fd, &buffers[0]);
    if (saved_crtc)
        drmModeFreeCrtc(saved_crtc);
    if (connector)
        drmModeFreeConnector(connector);
    if (resources)
        drmModeFreeResources(resources);
    if (master && fd >= 0)
        drmDropMaster(fd);
    if (fd >= 0)
        close(fd);
    return result;
}
