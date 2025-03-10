import CoreGraphics
import simd

extension float4x4 {
    // Create an orthographic (parallel) projection matrix that maps from an
    // arbitrary viewport bounded by the provided extents to Metal clip space.
    // Assumes originating space is right-handed.
    static func orthographicProjection(left: Float, top: Float,
                                       right: Float, bottom: Float,
                                       near: Float, far: Float) -> float4x4
    {
        let xs = 2 / (right - left)
        let ys = 2 / (top - bottom)
        let zs = -1 / (far - near)
        let tx = (left + right) / (left - right)
        let ty = (top + bottom) / (bottom - top)
        let tz = -near / (far - near)
        return float4x4([
            SIMD4<Float>(xs,  0,  0, 0),
            SIMD4<Float>( 0, ys,  0, 0),
            SIMD4<Float>( 0,  0, zs, 0),
            SIMD4<Float>(tx, ty, tz, 1)
        ])
    }

    init(_ transform: CGAffineTransform) {
        self.init(SIMD4<Float>( Float(transform.a),  Float(transform.b), 0, 0),
                  SIMD4<Float>( Float(transform.c),  Float(transform.d), 0, 0),
                  SIMD4<Float>(                  0,                   0, 1, 0),
                  SIMD4<Float>(Float(transform.tx), Float(transform.ty), 0, 1))
    }
}

func transformForAspectFitting(_ rectToFit: CGRect, in boundingRect: CGRect) -> float4x4 {
    let innerAspect = rectToFit.width / rectToFit.height
    let outerAspect = boundingRect.width / boundingRect.height
    var scale: Float = 1.0
    if (innerAspect < outerAspect) {
        scale = Float(boundingRect.height / rectToFit.height)
    } else {
        scale = Float(boundingRect.width / rectToFit.width)
    }
    let tx = Float(boundingRect.midX - rectToFit.midX)
    let ty = Float(boundingRect.midY - rectToFit.midY)
    let cx = Float(rectToFit.midX)
    let cy = Float(rectToFit.midY)
    let T = float4x4(SIMD4<Float>(scale, 0, 0, 0),
                     SIMD4<Float>(0, scale, 0, 0),
                     SIMD4<Float>(0, 0, 1, 0),
                     SIMD4<Float>(cx + tx - cx * scale, cy + ty - cy * scale, 0, 1))
    return T
}
