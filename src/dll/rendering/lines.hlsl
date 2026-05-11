struct Vertex {
    float3 position : position;
    float4 color : color;
};

struct Pixel {
    float4 position: SV_POSITION;
    float4 color : COLOR;
};

cbuffer Constants : register(b0) {
    float4x4 world_to_clip;
}

Pixel vs_main(Vertex vertex) {
    Pixel pixel;
    pixel.position = mul(float4(vertex.position, 1.0), world_to_clip);
    pixel.color = vertex.color;
    return pixel;
}

float4 ps_main(Pixel pixel) : SV_TARGET {
    return pixel.color;
}
