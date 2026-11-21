package com.example.walk_on_photos

import android.app.Activity
import android.graphics.BitmapFactory
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import com.google.ar.core.Anchor
import com.google.ar.core.Camera
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.IntBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * ARCore camera feed + the reconstructed photo anchored in the room.
 *
 * The photo's original camera is anchored at the phone's pose (yaw only,
 * gravity aligned), so the first view matches the photo and physically
 * walking forward walks into it.
 */
class ArPhotoView(
    private val activity: Activity,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, GLSurfaceView.Renderer, MethodChannel.MethodCallHandler {

    private val surface = GLSurfaceView(activity)
    private val channel = MethodChannel(messenger, "walk_on_photos/ar_view_$viewId")
    private val main = Handler(Looper.getMainLooper())

    private var session: Session? = null
    private val background = BackgroundRenderer()
    private val meshes = mutableListOf<MeshRenderer>()
    private var anchor: Anchor? = null

    @Volatile private var pendingLayers: List<LayerData>? = null
    @Volatile private var placeRequested = false
    @Volatile private var displayChanged = false
    private var viewportWidth = 1
    private var viewportHeight = 1
    private var lastTracking = ""

    private val proj = FloatArray(16)
    private val view = FloatArray(16)
    private val model = FloatArray(16)
    private val modelView = FloatArray(16)
    private val mvp = FloatArray(16)

    init {
        surface.preserveEGLContextOnPause = true
        surface.setEGLContextClientVersion(3)
        surface.setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        surface.setRenderer(this)
        surface.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        channel.setMethodCallHandler(this)
        resumeSession()
    }

    override fun getView(): View = surface

    override fun dispose() {
        channel.setMethodCallHandler(null)
        surface.onPause()
        session?.pause()
        session?.close()
        session = null
    }

    private fun resumeSession() {
        try {
            val s = session ?: Session(activity).also { created ->
                val config = Config(created)
                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                config.focusMode = Config.FocusMode.AUTO
                config.planeFindingMode = Config.PlaneFindingMode.DISABLED
                created.configure(config)
                session = created
            }
            s.resume()
            surface.onResume()
            displayChanged = true
        } catch (e: Exception) {
            sendTracking("error:${e.message}")
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadScene" -> {
                @Suppress("UNCHECKED_CAST")
                val layers = call.argument<List<Map<String, Any>>>("layers")
                if (layers == null) {
                    result.error("bad_args", "layers missing", null)
                    return
                }
                pendingLayers = layers.map {
                    LayerData(
                        positions = it["positions"] as FloatArray,
                        uvs = it["uvs"] as FloatArray,
                        indices = it["indices"] as IntArray,
                        png = it["texture"] as ByteArray,
                    )
                }
                result.success(null)
            }
            "placeHere" -> {
                placeRequested = true
                result.success(null)
            }
            "pause" -> {
                surface.onPause()
                session?.pause()
                result.success(null)
            }
            "resume" -> {
                resumeSession()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ GL thread

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        background.create()
        // Textures/buffers were lost with the old context: re-upload.
        meshes.forEach { it.contextLost() }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        viewportWidth = width
        viewportHeight = height
        GLES30.glViewport(0, 0, width, height)
        displayChanged = true
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT or GLES30.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        if (displayChanged) {
            s.setDisplayGeometry(displayRotation(), viewportWidth, viewportHeight)
            displayChanged = false
        }
        s.setCameraTextureName(background.textureId)
        val frame: Frame = try {
            s.update()
        } catch (e: Exception) {
            return
        }
        background.draw(frame)

        val camera = frame.camera
        reportTracking(camera)

        pendingLayers?.let { layers ->
            pendingLayers = null
            meshes.forEach { it.release() }
            meshes.clear()
            layers.forEach { meshes.add(MeshRenderer(it)) }
            placeRequested = true
        }

        if (placeRequested && camera.trackingState == TrackingState.TRACKING) {
            placeRequested = false
            anchor?.detach()
            anchor = s.createAnchor(placementPose(camera.pose))
            main.post { channel.invokeMethod("onPlaced", null) }
        }

        val a = anchor ?: return
        if (camera.trackingState != TrackingState.TRACKING) return
        camera.getProjectionMatrix(proj, 0, 0.03f, 100f)
        camera.getViewMatrix(view, 0)
        a.pose.toMatrix(model, 0)
        Matrix.multiplyMM(modelView, 0, view, 0, model, 0)
        Matrix.multiplyMM(mvp, 0, proj, 0, modelView, 0)
        meshes.forEach { it.draw(mvp) }
    }

    /** Photo camera = phone position, facing the phone's heading, level. */
    private fun placementPose(cameraPose: Pose): Pose {
        val z = cameraPose.zAxis
        val fx = -z[0]
        val fz = -z[2]
        val yaw = atan2(-fx, -fz)
        val q = floatArrayOf(0f, sin(yaw / 2f), 0f, cos(yaw / 2f))
        return Pose(cameraPose.translation, q)
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: 0
        } else {
            activity.windowManager.defaultDisplay.rotation
        }

    private fun reportTracking(camera: Camera) {
        val state = when (camera.trackingState) {
            TrackingState.TRACKING -> "normal"
            TrackingState.STOPPED -> "notAvailable"
            else -> when (camera.trackingFailureReason) {
                TrackingFailureReason.EXCESSIVE_MOTION -> "limited:excessiveMotion"
                TrackingFailureReason.INSUFFICIENT_FEATURES -> "limited:insufficientFeatures"
                TrackingFailureReason.INSUFFICIENT_LIGHT -> "limited:insufficientLight"
                TrackingFailureReason.BAD_STATE -> "limited:relocalizing"
                else -> "limited:initializing"
            }
        }
        if (state != lastTracking) {
            lastTracking = state
            sendTracking(state)
        }
    }

    private fun sendTracking(state: String) {
        main.post { channel.invokeMethod("onTracking", state) }
    }
}

class LayerData(
    val positions: FloatArray,
    val uvs: FloatArray,
    val indices: IntArray,
    val png: ByteArray,
)

// ------------------------------------------------------------------ GL utils

private fun floatBuffer(data: FloatArray): FloatBuffer =
    ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder())
        .asFloatBuffer().apply { put(data); position(0) }

private fun intBuffer(data: IntArray): IntBuffer =
    ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder())
        .asIntBuffer().apply { put(data); position(0) }

private fun compile(type: Int, src: String): Int {
    val shader = GLES30.glCreateShader(type)
    GLES30.glShaderSource(shader, src)
    GLES30.glCompileShader(shader)
    val ok = IntArray(1)
    GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, ok, 0)
    if (ok[0] == 0) {
        val log = GLES30.glGetShaderInfoLog(shader)
        GLES30.glDeleteShader(shader)
        throw RuntimeException("Shader compile failed: $log")
    }
    return shader
}

private fun link(vs: String, fs: String): Int {
    val program = GLES30.glCreateProgram()
    GLES30.glAttachShader(program, compile(GLES30.GL_VERTEX_SHADER, vs))
    GLES30.glAttachShader(program, compile(GLES30.GL_FRAGMENT_SHADER, fs))
    GLES30.glLinkProgram(program)
    return program
}

/** Draws the ARCore camera image (external OES texture) full-screen. */
private class BackgroundRenderer {
    var textureId = -1
        private set
    private var program = 0
    private var aPos = 0
    private var aTex = 0
    private val quad = floatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val quadTex = floatBuffer(FloatArray(8))

    fun create() {
        val tex = IntArray(1)
        GLES30.glGenTextures(1, tex, 0)
        textureId = tex[0]
        val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        GLES30.glBindTexture(target, textureId)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        program = link(
            """
            attribute vec4 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { gl_Position = a_Position; v_TexCoord = a_TexCoord; }
            """.trimIndent(),
            """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v_TexCoord;
            uniform samplerExternalOES u_Texture;
            void main() { gl_FragColor = texture2D(u_Texture, v_TexCoord); }
            """.trimIndent(),
        )
        aPos = GLES30.glGetAttribLocation(program, "a_Position")
        aTex = GLES30.glGetAttribLocation(program, "a_TexCoord")
    }

    fun draw(frame: Frame) {
        if (frame.hasDisplayGeometryChanged()) {
            quad.position(0)
            quadTex.position(0)
            frame.transformCoordinates2d(
                Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, quad,
                Coordinates2d.TEXTURE_NORMALIZED, quadTex,
            )
        }
        if (frame.timestamp == 0L) return
        quad.position(0)
        quadTex.position(0)
        GLES30.glDisable(GLES30.GL_DEPTH_TEST)
        GLES30.glDepthMask(false)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES30.glUseProgram(program)
        GLES30.glVertexAttribPointer(aPos, 2, GLES30.GL_FLOAT, false, 0, quad)
        GLES30.glVertexAttribPointer(aTex, 2, GLES30.GL_FLOAT, false, 0, quadTex)
        GLES30.glEnableVertexAttribArray(aPos)
        GLES30.glEnableVertexAttribArray(aTex)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glDisableVertexAttribArray(aPos)
        GLES30.glDisableVertexAttribArray(aTex)
        GLES30.glDepthMask(true)
        GLES30.glEnable(GLES30.GL_DEPTH_TEST)
    }
}

/** One textured photo layer with a real depth buffer. */
private class MeshRenderer(private val data: LayerData) {
    private var program = 0
    private var aPos = 0
    private var aUv = 0
    private var uMvp = 0
    private val buffers = IntArray(3)
    private val texture = IntArray(1)
    private var uploaded = false

    fun contextLost() {
        uploaded = false
    }

    private fun upload() {
        program = link(
            """
            #version 300 es
            in vec3 a_Position;
            in vec2 a_Uv;
            uniform mat4 u_Mvp;
            out vec2 v_Uv;
            void main() { gl_Position = u_Mvp * vec4(a_Position, 1.0); v_Uv = a_Uv; }
            """.trimIndent(),
            """
            #version 300 es
            precision mediump float;
            in vec2 v_Uv;
            uniform sampler2D u_Texture;
            out vec4 fragColor;
            void main() { fragColor = texture(u_Texture, v_Uv); }
            """.trimIndent(),
        )
        aPos = GLES30.glGetAttribLocation(program, "a_Position")
        aUv = GLES30.glGetAttribLocation(program, "a_Uv")
        uMvp = GLES30.glGetUniformLocation(program, "u_Mvp")

        GLES30.glGenBuffers(3, buffers, 0)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffers[0])
        GLES30.glBufferData(
            GLES30.GL_ARRAY_BUFFER, data.positions.size * 4,
            floatBuffer(data.positions), GLES30.GL_STATIC_DRAW,
        )
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffers[1])
        GLES30.glBufferData(
            GLES30.GL_ARRAY_BUFFER, data.uvs.size * 4,
            floatBuffer(data.uvs), GLES30.GL_STATIC_DRAW,
        )
        GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, buffers[2])
        GLES30.glBufferData(
            GLES30.GL_ELEMENT_ARRAY_BUFFER, data.indices.size * 4,
            intBuffer(data.indices), GLES30.GL_STATIC_DRAW,
        )
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)
        GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, 0)

        // Bitmap row 0 = texture t 0, which matches the top-left uv origin.
        val bitmap = BitmapFactory.decodeByteArray(data.png, 0, data.png.size)
        GLES30.glGenTextures(1, texture, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture[0])
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR_MIPMAP_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
        GLES30.glGenerateMipmap(GLES30.GL_TEXTURE_2D)
        bitmap.recycle()
        uploaded = true
    }

    fun draw(mvp: FloatArray) {
        if (!uploaded) upload()
        GLES30.glEnable(GLES30.GL_DEPTH_TEST)
        GLES30.glDisable(GLES30.GL_CULL_FACE)
        GLES30.glUseProgram(program)
        GLES30.glUniformMatrix4fv(uMvp, 1, false, mvp, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture[0])

        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffers[0])
        GLES30.glVertexAttribPointer(aPos, 3, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glEnableVertexAttribArray(aPos)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buffers[1])
        GLES30.glVertexAttribPointer(aUv, 2, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glEnableVertexAttribArray(aUv)
        GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, buffers[2])
        GLES30.glDrawElements(GLES30.GL_TRIANGLES, data.indices.size, GLES30.GL_UNSIGNED_INT, 0)

        GLES30.glDisableVertexAttribArray(aPos)
        GLES30.glDisableVertexAttribArray(aUv)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)
        GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, 0)
    }

    fun release() {
        if (!uploaded) return
        GLES30.glDeleteBuffers(3, buffers, 0)
        GLES30.glDeleteTextures(1, texture, 0)
        GLES30.glDeleteProgram(program)
        uploaded = false
    }
}
