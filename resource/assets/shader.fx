texture gTextureA;
texture gTextureB;
float gBlend = 0.0f;
float gAlpha = 1.0f;

sampler Sampler0 = sampler_state
{
    Texture = (gTextureA);
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
};

sampler Sampler1 = sampler_state
{
    Texture = (gTextureB);
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
};

float4 PS(float2 Tex : TEXCOORD0) : COLOR0
{
    float4 a = tex2D(Sampler0, Tex);
    float4 b = tex2D(Sampler1, Tex);
    float4 outColor = lerp(a, b, saturate(gBlend));
    return outColor * saturate(gAlpha);
}

technique ReplaceTexture
{
    pass P0
    {
        PixelShader = compile ps_2_0 PS();
    }
}
