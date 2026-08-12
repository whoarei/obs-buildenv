#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef EGLDisplay(EGLAPIENTRYP get_platform_display_ext_fn)(EGLenum, void *,
                                                              const EGLint *);

static void fail(const char *message)
{
    fprintf(stderr, "FAIL: %s (EGL error 0x%04x)\n", message, eglGetError());
    exit(EXIT_FAILURE);
}

int main(void)
{
    get_platform_display_ext_fn get_platform_display =
        (get_platform_display_ext_fn)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay display;
    EGLConfig config;
    EGLContext context;
    EGLSurface surface;
    EGLint major = 0, minor = 0, count = 0;
    unsigned char pixel[4] = {0, 0, 0, 0};
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};

    if (get_platform_display != NULL)
        display = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                                       EGL_DEFAULT_DISPLAY, NULL);
    else
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY)
        fail("no EGL display");
    if (!eglInitialize(display, &major, &minor))
        fail("eglInitialize");
    if (!eglBindAPI(EGL_OPENGL_ES_API))
        fail("eglBindAPI(EGL_OPENGL_ES_API)");
    if (!eglChooseConfig(display, config_attributes, &config, 1, &count) || count != 1)
        fail("eglChooseConfig");
    surface = eglCreatePbufferSurface(display, config, surface_attributes);
    if (surface == EGL_NO_SURFACE)
        fail("eglCreatePbufferSurface");
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (context == EGL_NO_CONTEXT)
        fail("eglCreateContext");
    if (!eglMakeCurrent(display, surface, surface, context))
        fail("eglMakeCurrent");

    glViewport(0, 0, 1, 1);
    glClearColor(0.25f, 0.50f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    if (glGetError() != GL_NO_ERROR)
        fail("glReadPixels");

    printf("EGL %d.%d vendor=%s version=%s\n", major, minor,
           eglQueryString(display, EGL_VENDOR), eglQueryString(display, EGL_VERSION));
    printf("GLES vendor=%s renderer=%s version=%s\n", glGetString(GL_VENDOR),
           glGetString(GL_RENDERER), glGetString(GL_VERSION));
    printf("pixel=%u,%u,%u,%u\n", pixel[0], pixel[1], pixel[2], pixel[3]);

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);

    if (pixel[0] < 62 || pixel[0] > 66 || pixel[1] < 126 || pixel[1] > 130 ||
        pixel[2] < 190 || pixel[2] > 194 || pixel[3] != 255) {
        fprintf(stderr, "FAIL: unexpected rendered pixel\n");
        return EXIT_FAILURE;
    }
    puts("PASS: EGL initialized and GLES rendered/read back the expected pixel");
    return EXIT_SUCCESS;
}
