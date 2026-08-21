#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 captured = texture(source, qt_TexCoord0);
    float contentAlpha = smoothstep(0.35, 0.95, captured.a);
    vec3 unpremultiplied = captured.rgb / max(captured.a, 0.001);

    fragColor = vec4(unpremultiplied * contentAlpha, contentAlpha) * qt_Opacity;
}
