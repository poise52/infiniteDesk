struct Viewport { size: vec2<f32>, _pad: vec2<f32> };
@group(0) @binding(0) var<uniform> viewport: Viewport;
struct Input {
    @location(0) rect: vec4<f32>,
    @location(1) color: vec4<f32>,
    @location(2) depth: f32,
};
struct Output {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};
@vertex fn vs_main(input: Input, @builtin(vertex_index) vertex: u32) -> Output {
    let corners = array<vec2<f32>, 6>(vec2(0., 0.), vec2(1., 0.), vec2(0., 1.), vec2(0., 1.), vec2(1., 0.), vec2(1., 1.));
    let pixel = mix(input.rect.xy, input.rect.zw, corners[vertex]);
    var out: Output;
    out.position = vec4(pixel.x / viewport.size.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.size.y * 2.0, input.depth, 1.0);
    out.color = input.color;
    return out;
}
@fragment fn fs_main(input: Output) -> @location(0) vec4<f32> { return input.color; }
