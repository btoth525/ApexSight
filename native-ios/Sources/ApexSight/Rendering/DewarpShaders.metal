#include <metal_stdlib>
using namespace metal;

// Fisheye dewarp + virtual PTZ.
// One full-screen-triangle pass: for each output pixel, compute a 3-D ray from the
// virtual camera (pan/tilt/zoom uniforms), find where that ray lands on the fisheye
// disc using the equidistant lens model (r = f·θ), sample the NV12 source there, and
// convert BT.709 video-range YUV → RGB. No compute pass, no intermediate targets.
//
// Must stay field-for-field in sync with DewarpUniformsData in DewarpUniforms.swift.

struct DewarpUniforms {
    float centerX;    // fisheye circle centre in the source image, 0–1
    float centerY;
    float radius;     // circle radius as a fraction of image height
    float lensFOV;    // physical lens FOV in radians (Reolink fisheye ≈ 200° = 3.49)
    float outputFOV;  // virtual camera FOV in radians
    float pan;        // aim: rotation about the vertical axis
    float tilt;       // aim: 0 = straight down (ceiling nadir), π/2 = horizon
    float zoom;       // extra zoom factor, 1 = none
    float texAspect;  // source W/H, set per frame
    float viewAspect; // drawable W/H, set per frame
    int   mode;       // 0 passthrough, 1 panorama, 2 rectilinear PTZ, 3 little planet
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle — 3 vertices, no buffers; hardware clips to the viewport.
vertex VSOut dewarpVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = pos[vid];
    VSOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return out;
}

// Aspect-fill for passthrough: shrink the wider axis so the video fills the pane
// without bars or stretching.
static float2 fillUV(float2 uv, float texAspect, float viewAspect) {
    float2 scale = float2(1.0, 1.0);
    if (viewAspect > texAspect) {
        scale.y = texAspect / viewAspect;
    } else {
        scale.x = viewAspect / texAspect;
    }
    return (uv - 0.5) * scale + 0.5;
}

// Project a unit ray (fisheye axis = +Z) onto the source image via the
// equidistant model: image radius ∝ angle from the optical axis.
static float2 fisheyeUV(float theta, float phi, constant DewarpUniforms &u) {
    float rNorm = theta / (u.lensFOV * 0.5);   // 0 at centre, 1 at the lens edge
    return float2(u.centerX + rNorm * (u.radius / u.texAspect) * cos(phi),
                  u.centerY + rNorm * u.radius * sin(phi));
}

fragment float4 dewarpFragment(VSOut in [[stage_in]],
                               texture2d<float, access::sample> yTex    [[texture(0)]],
                               texture2d<float, access::sample> cbcrTex [[texture(1)]],
                               constant DewarpUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 srcUV;
    float theta = 0.0;
    bool isFisheye = (u.mode != 0);

    if (u.mode == 2) {
        // Rectilinear virtual PTZ — drag to look around, pinch to zoom.
        float tanHalf = tan(u.outputFOV * 0.5) / max(u.zoom, 0.2);
        float sx = (in.uv.x - 0.5) * 2.0 * tanHalf * u.viewAspect;
        float sy = (0.5 - in.uv.y) * 2.0 * tanHalf;

        // Level-horizon basis: `right` stays horizontal so panning never rolls the image.
        float3 fwd   = float3(sin(u.tilt) * cos(u.pan), sin(u.tilt) * sin(u.pan), cos(u.tilt));
        float3 right = float3(-sin(u.pan), cos(u.pan), 0.0);
        float3 up    = cross(right, fwd);
        float3 dir   = normalize(fwd + sx * right + sy * up);

        theta = acos(clamp(dir.z, -1.0, 1.0));
        float phi = atan2(dir.y, dir.x);
        srcUV = fisheyeUV(theta, phi, u);
    } else if (u.mode == 1) {
        // Panorama — x sweeps azimuth around the lens, y sweeps elevation.
        // 180° at zoom 1 (2π across a phone width is unreadable); pinch out for more.
        float coverage = M_PI_F / max(u.zoom, 0.5);
        float phi = (in.uv.x - 0.5) * coverage + u.pan;
        // Elevation band, top = out toward the lens rim (high on the walls for a
        // ceiling cam), bottom = near nadir. The reverse mapping renders the room
        // upside down and mirror-writes wall text (verified live).
        float edge = u.lensFOV * 0.5;
        theta = mix(edge * 0.995, edge * 0.15, in.uv.y);
        srcUV = fisheyeUV(theta, phi, u);
    } else if (u.mode == 3) {
        // Little planet — stereographic projection of the hemisphere onto a disc.
        float2 c = float2((in.uv.x - 0.5) * 2.0 * u.viewAspect, (in.uv.y - 0.5) * 2.0);
        c /= max(u.zoom, 0.2);
        float r = length(c);
        theta = 2.0 * atan(r);                 // stereographic: r = tan(θ/2)
        float phi = atan2(c.y, c.x) + u.pan;
        srcUV = fisheyeUV(theta, phi, u);
    } else {
        // Passthrough — plain aspect-fill of the raw frame.
        srcUV = fillUV(in.uv, u.texAspect, u.viewAspect);
    }

    float yV     = yTex.sample(s, srcUV).r;
    float2 cbcr  = cbcrTex.sample(s, srcUV).rg;

    // BT.709, video range (16–235 luma / 16–240 chroma) — the correct matrix for IP cameras.
    float Y  = (yV - 0.0627) * 1.164;
    float Cb = (cbcr.x - 0.5) * 1.138;
    float Cr = (cbcr.y - 0.5) * 1.138;
    float3 rgb = float3(Y + 1.793 * Cr,
                        Y - 0.213 * Cb - 0.533 * Cr,
                        Y + 2.112 * Cb);

    if (isFisheye) {
        // Fade smoothly at the lens rim and the texture border instead of a hard edge.
        float edge = u.lensFOV * 0.5;
        float aa = 1.0 - smoothstep(edge * 0.98, edge, theta);
        aa *= smoothstep(0.0, 0.004, srcUV.x) * smoothstep(0.0, 0.004, 1.0 - srcUV.x);
        aa *= smoothstep(0.0, 0.004, srcUV.y) * smoothstep(0.0, 0.004, 1.0 - srcUV.y);
        float3 bg = float3(0.02, 0.02, 0.03);
        rgb = mix(bg, saturate(rgb), aa);
    }

    return float4(saturate(rgb), 1.0);
}
