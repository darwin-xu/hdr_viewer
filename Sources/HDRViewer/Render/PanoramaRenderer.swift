import Foundation
import Metal
import simd

// MARK: - 360° Panorama Renderer
//
// Renders either equirectangular or dual-fisheye 360° textures onto a
// full-screen triangle using a rectilinear (perspective) projection
// controlled by yaw, pitch, and field-of-view.
//
// Two pipeline states are compiled from MSL source:
//   • `pano_fragment`       – for equirectangular (2:1) input
//   • `pano_fragment_dfisheye` – for dual-fisheye (1:1) input
//
// Metal shaders are compiled at runtime from source because SPM does not
// compile .metal files.

/// Which panoramic projection the source texture uses.
enum PanoProjectionMode {
    case equirectangular
    case dualFisheye
}

final class PanoramaRenderer {
    private let device: MTLDevice
    private let equirectPipeline: MTLRenderPipelineState
    private let dfisheyePipeline: MTLRenderPipelineState
    private let uniformBuffer: MTLBuffer

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vert = library.makeFunction(name: "pano_vertex"),
              let fragEqui = library.makeFunction(name: "pano_fragment"),
              let fragDF = library.makeFunction(name: "pano_fragment_dfisheye") else {
            throw PanoError.shaderNotFound
        }

        let descEqui = MTLRenderPipelineDescriptor()
        descEqui.vertexFunction = vert
        descEqui.fragmentFunction = fragEqui
        descEqui.colorAttachments[0].pixelFormat = pixelFormat
        equirectPipeline = try device.makeRenderPipelineState(descriptor: descEqui)

        let descDF = MTLRenderPipelineDescriptor()
        descDF.vertexFunction = vert
        descDF.fragmentFunction = fragDF
        descDF.colorAttachments[0].pixelFormat = pixelFormat
        dfisheyePipeline = try device.makeRenderPipelineState(descriptor: descDF)

        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<PanoUniforms>.stride,
            options: .storageModeShared
        )!
    }

    /// Draw the panorama onto the current render pass.
    ///
    /// - Parameters:
    ///   - encoder: A render command encoder whose render pass targets the drawable.
    ///   - texture: The source texture (equirectangular or dual-fisheye).
    ///   - yaw: Horizontal look angle in **radians** (positive = right).
    ///   - pitch: Vertical look angle in **radians** (positive = up), clamped ±π/2.
    ///   - fov: Vertical field-of-view in **degrees**.
    ///   - drawableSize: Drawable pixel dimensions (for aspect ratio).
    ///   - mode: Source projection type.
    func draw(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        yaw: Float,
        pitch: Float,
        fov: Float,
        drawableSize: CGSize,
        mode: PanoProjectionMode = .equirectangular
    ) {
        var uniforms = PanoUniforms(
            yaw: yaw,
            pitch: pitch,
            fov: fov,
            aspect: Float(drawableSize.width / drawableSize.height)
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<PanoUniforms>.stride)

        switch mode {
        case .equirectangular: encoder.setRenderPipelineState(equirectPipeline)
        case .dualFisheye:     encoder.setRenderPipelineState(dfisheyePipeline)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        // Full-screen triangle (3 vertices generated in vertex shader)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - Offscreen texture management

    /// Create (or reuse) an offscreen rgba16Float texture sized to the
    /// given extent.  Returns `nil` if the device can't create it.
    func offscreenTexture(
        width: Int,
        height: Int,
        existing: MTLTexture?
    ) -> MTLTexture? {
        if let tex = existing,
           tex.width == width,
           tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }
}

// MARK: - Uniforms

struct PanoUniforms {
    var yaw: Float
    var pitch: Float
    var fov: Float       // vertical FOV in degrees
    var aspect: Float    // width / height
}

// MARK: - Errors

enum PanoError: LocalizedError {
    case shaderNotFound

    var errorDescription: String? {
        switch self {
        case .shaderNotFound:
            return "Failed to load panorama Metal shader functions."
        }
    }
}

// MARK: - Metal Shader Source (MSL)

extension PanoramaRenderer {
    /// Metal Shading Language source compiled at runtime.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PanoUniforms {
        float yaw;
        float pitch;
        float fov;     // vertical FOV in degrees
        float aspect;  // width / height
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Full-screen triangle trick: 3 vertices that cover NDC [-1,1]².
    vertex VertexOut pano_vertex(uint vid [[vertex_id]]) {
        float2 pos;
        pos.x = (vid == 1) ? 3.0 : -1.0;
        pos.y = (vid == 2) ? 3.0 : -1.0;

        VertexOut out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = pos * 0.5 + 0.5;
        return out;
    }

    // ─── Helper: compute world-space ray from screen UV and camera ───
    // Uses **stereographic** projection instead of rectilinear:
    //   r = 2·tan(θ/2)  ⟹  θ = 2·atan(r/2)
    // This is conformal (preserves local shapes), produces much less
    // edge distortion at wide FOV, and can represent up to ~360°.
    static float3 screenToWorldRay(float2 uv, constant PanoUniforms &u) {
        float2 ndc = uv * 2.0 - 1.0;
        // Stereographic scale: S = 2·tan(fov/4)
        float fovRad = u.fov * M_PI_F / 180.0;
        float S = 2.0 * tan(fovRad * 0.25);
        float2 scaled = float2(ndc.x * u.aspect * S, ndc.y * S);
        float r = length(scaled);
        // θ = 2·atan(r/2) — stereographic inverse
        float theta = 2.0 * atan(r * 0.5);
        // Build local camera-space direction from θ and the 2D direction
        float sinT = sin(theta);
        float cosT = cos(theta);
        float2 unit = (r > 1e-6) ? (scaled / r) : float2(0.0, 0.0);
        float3 dir = float3(sinT * unit.x, sinT * unit.y, -cosT);
        // Pitch (X axis)
        float cp = cos(u.pitch), sp = sin(u.pitch);
        float3 d1 = float3(dir.x,
                            dir.y * cp - dir.z * sp,
                            dir.y * sp + dir.z * cp);
        // Yaw (Y axis)
        float cy = cos(u.yaw), sy = sin(u.yaw);
        return float3(d1.x * cy + d1.z * sy,
                       d1.y,
                       -d1.x * sy + d1.z * cy);
    }

    // ─── Equirectangular fragment shader ─────────────────────────────
    fragment float4 pano_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        constant PanoUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::repeat, filter::linear);
        float3 d = screenToWorldRay(in.uv, u);

        float lon = atan2(d.x, -d.z);
        float lat = asin(clamp(d.y, -1.0f, 1.0f));

        float2 tc = float2(lon / (2.0 * M_PI_F) + 0.5,
                            lat / M_PI_F + 0.5);
        return tex.sample(s, tc);
    }

    // ─── Dual-fisheye fragment shader ────────────────────────────────
    //
    // Input: texture with two circular fisheye images side-by-side.
    // Supports both 2:1 (hstacked from separate streams) and 1:1
    // (single-frame dual-fisheye) textures automatically.
    //
    //   • Front lens – centre of left half, pointing towards +Z (camera forward)
    //   • Rear  lens – centre of right half, pointing towards -Z (camera back)
    //
    // Each lens has ~190-200° FOV (equidistant projection).
    // The circle inscribes in the smaller dimension of each half.
    //
    // Strategy:
    //   1. Compute world-space ray from camera orientation.
    //   2. Pick front or rear lens based on ray.z sign.
    //   3. Project ray into that lens's local fisheye UV space.
    //   4. Blend in the overlap zone for seamless stitching.
    //
    // NOTE: The CIContext render that fills this texture is Y-flipped
    // (CIImage origin bottom-left → Metal texture origin top-left),
    // so increasing V = *up* in the original frame.  The sin(phi)
    // sign is positive to match this convention.
    //
    fragment float4 pano_fragment_dfisheye(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        constant PanoUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 d = screenToWorldRay(in.uv, u);

        // Per-lens FOV in radians (Insta360 ~200°, use 195° for safety)
        const float lensFOV = 195.0 * M_PI_F / 180.0;
        const float maxTheta = lensFOV * 0.5;  // max angle from lens axis

        // ── Compute circle radii in UV, adapting to texture aspect ──
        // Each half of the texture contains one fisheye circle.
        // The circle inscribes in the smaller of (half-width, height).
        float texW = float(tex.get_width());
        float texH = float(tex.get_height());
        float halfW = texW * 0.5;  // pixel width of each half

        // Circle radius in pixels = min(halfW, texH) / 2
        float circlePixR = min(halfW, texH) * 0.5;
        float circleR_u = circlePixR / texW;   // radius in U
        float circleR_v = circlePixR / texH;   // radius in V

        // Lens centres in texture UV
        const float2 frontCentre = float2(0.25, 0.5);
        const float2 rearCentre  = float2(0.75, 0.5);

        // ── Front lens ──
        // Lens axis = camera forward.  We define camera forward as -Z
        // in the screenToWorldRay helper, so the front lens captures
        // the direction where d.z < 0.
        // theta = angle from lens axis (-Z):
        float thetaF = acos(clamp(-d.z, -1.0f, 1.0f));
        // phi = azimuth in the X-Y plane (perpendicular to -Z):
        float phiF   = atan2(d.y, d.x);
        float rNormF = thetaF / maxTheta;
        float2 uvF   = frontCentre + float2(rNormF * circleR_u * cos(phiF),
                                             rNormF * circleR_v * sin(phiF));

        // ── Rear lens ──
        // Lens axis = +Z (behind the camera).
        // X is mirrored when looking in the +Z direction.
        float thetaR = acos(clamp(d.z, -1.0f, 1.0f));
        float phiR   = atan2(d.y, -d.x);
        float rNormR = thetaR / maxTheta;
        float2 uvR   = rearCentre + float2(rNormR * circleR_u * cos(phiR),
                                            rNormR * circleR_v * sin(phiR));

        float4 colF = tex.sample(s, uvF);
        float4 colR = tex.sample(s, uvR);

        // Blend weight: 1 = fully front, 0 = fully rear.
        // Uses smoothstep on theta from lens axis for soft crossfade
        // in the overlap region near the equator.
        float wF = smoothstep(maxTheta, maxTheta - 0.18, thetaF);
        float wR = smoothstep(maxTheta, maxTheta - 0.18, thetaR);

        // Normalise weights
        float total = wF + wR;
        if (total < 0.001) return float4(0, 0, 0, 1);  // outside both circles
        wF /= total;
        wR /= total;

        return colF * wF + colR * wR;
    }
    """
}
