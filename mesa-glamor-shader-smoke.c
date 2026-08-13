#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>

typedef GLuint (*PFNGLCREATESHADERPROC)(GLenum);
typedef void (*PFNGLSHADERSOURCEPROC)(GLuint, GLsizei, const GLchar *const *, const GLint *);
typedef void (*PFNGLCOMPILESHADERPROC)(GLuint);
typedef void (*PFNGLGETSHADERIVPROC)(GLuint, GLenum, GLint *);
typedef void (*PFNGLGETSHADERINFOLOGPROC)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef void (*PFNGLDELETESHADERPROC)(GLuint);

static void *get_proc(const char *name)
{
    void *proc = (void *)eglGetProcAddress(name);
    if (!proc) {
        fprintf(stderr, "FAIL: missing %s\n", name);
        exit(1);
    }
    return proc;
}

int main(void)
{
    static const char shader_source[] =
        "precision highp float;\n"
        "attribute vec4 v_position;\n"
        "attribute vec4 v_texcoord;\n"
        "varying vec2 source_texture;\n"
        "void main()\n"
        "{\n"
        "    gl_Position = v_position;\n"
        "    source_texture = v_texcoord.xy;\n"
        "}\n";
    static const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_NONE,
    };
    static const EGLint pbuffer_attributes[] = {
        EGL_WIDTH, 16,
        EGL_HEIGHT, 16,
        EGL_NONE,
    };
    EGLDisplay display;
    EGLConfig config;
    EGLContext context;
    EGLSurface surface;
    EGLint count;
    GLint status;
    GLchar log[2048];
    GLsizei log_length = 0;
    GLuint shader;
    PFNGLCREATESHADERPROC create_shader;
    PFNGLSHADERSOURCEPROC shader_source_fn;
    PFNGLCOMPILESHADERPROC compile_shader;
    PFNGLGETSHADERIVPROC get_shader_iv;
    PFNGLGETSHADERINFOLOGPROC get_shader_info_log;
    PFNGLDELETESHADERPROC delete_shader;

    display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                    EGL_DEFAULT_DISPLAY, NULL);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
        fprintf(stderr, "FAIL: EGL initialization error=0x%04x\n", eglGetError());
        return 1;
    }
    if (!eglBindAPI(EGL_OPENGL_API) ||
        !eglChooseConfig(display, config_attributes, &config, 1, &count) ||
        count != 1) {
        fprintf(stderr, "FAIL: OpenGL config error=0x%04x\n", eglGetError());
        return 1;
    }
    surface = eglCreatePbufferSurface(display, config, pbuffer_attributes);
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, NULL);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
        !eglMakeCurrent(display, surface, surface, context)) {
        fprintf(stderr, "FAIL: OpenGL context error=0x%04x\n", eglGetError());
        return 1;
    }

    create_shader = (PFNGLCREATESHADERPROC)get_proc("glCreateShader");
    shader_source_fn = (PFNGLSHADERSOURCEPROC)get_proc("glShaderSource");
    compile_shader = (PFNGLCOMPILESHADERPROC)get_proc("glCompileShader");
    get_shader_iv = (PFNGLGETSHADERIVPROC)get_proc("glGetShaderiv");
    get_shader_info_log = (PFNGLGETSHADERINFOLOGPROC)get_proc("glGetShaderInfoLog");
    delete_shader = (PFNGLDELETESHADERPROC)get_proc("glDeleteShader");

    shader = create_shader(GL_VERTEX_SHADER);
    const GLchar *source = shader_source;
    shader_source_fn(shader, 1, &source, NULL);
    compile_shader(shader);
    get_shader_iv(shader, GL_COMPILE_STATUS, &status);
    get_shader_info_log(shader, sizeof(log), &log_length, log);

    printf("GL vendor=%s renderer=%s version=%s GLSL=%s\n",
           glGetString(GL_VENDOR), glGetString(GL_RENDERER),
           glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
    if (!status) {
        fprintf(stderr, "FAIL: glamor shader compile failed:\n%.*s\n",
                (int)log_length, log);
        return 1;
    }
    printf("PASS: legacy Xorg glamor shader compiled\n");

    delete_shader(shader);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    return 0;
}
