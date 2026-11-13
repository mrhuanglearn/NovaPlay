package com.example.uzv.native_player.kernel.mpv

import android.content.Context
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * The GL surface libmpv draws into through its render API. The render context lives on the GL thread: created in
 * [onSurfaceCreated] (which fires again when the EGL context was lost), drawn in [onDrawFrame] whenever mpv reports a
 * new frame (MpvNative.onMpvRenderUpdate -> requestRender), freed on the GL thread by [releaseRenderContext].
 *
 * [onRenderReady] runs on the GL thread with true when a render context exists, false when mpv refused to create one.
 */
class MpvSurfaceView(
    context: Context,
    private val core: MpvCore,
    private val onRenderReady: (Boolean) -> Unit,
) : GLSurfaceView(context) {
    @Volatile private var renderContext = 0L
    private var surfaceWidth = 0
    private var surfaceHeight = 0

    private val renderer = object : Renderer {
        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            // A new GL context: whatever the old render context allocated died with the old one, so only the handle is dropped.
            if (renderContext != 0L) core.freeRenderContext(renderContext)
            renderContext = core.createRenderContext()
            onRenderReady(renderContext != 0L)
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            surfaceWidth = width
            surfaceHeight = height
            GLES20.glViewport(0, 0, width, height)
        }

        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            val ctx = renderContext
            if (ctx != 0L && surfaceWidth > 0 && surfaceHeight > 0) core.render(ctx, surfaceWidth, surfaceHeight)
        }
    }

    init {
        keepScreenOn = true
        holder.setKeepScreenOn(true)
        setEGLContextClientVersion(3) // mpv's OpenGL back end needs ES 3.0 for most of its shaders
        setEGLConfigChooser(8, 8, 8, 0, 0, 0)
        preserveEGLContextOnPause = true
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    /**
     * Frees the render context on the GL thread (mpv must not be destroyed while one exists). If the GL thread does not
     * answer in time (the view was detached and the thread is gone) the context is freed on the calling thread instead:
     * without a current GL context mpv's GL clean-up calls are ignored by the driver, which leaks nothing that outlives the EGL context.
     */
    fun releaseRenderContext(timeoutMs: Long) {
        val done = CountDownLatch(1)
        queueEvent {
            val ctx = renderContext
            renderContext = 0
            core.freeRenderContext(ctx)
            done.countDown()
        }
        if (!done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            val ctx = renderContext
            renderContext = 0
            core.freeRenderContext(ctx)
        }
    }
}
