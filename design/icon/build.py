#!/usr/bin/env python3
"""Render and composite the PipePlot icon. Requires POV-Ray, Pillow and macOS iconutil."""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
N = 2048
S = N / 1024

def box(b): return tuple(round(v*S) for v in b)
def width(v): return max(1, round(v*S))
def layer(): return Image.new('RGBA', (N,N))
def rounded(draw, b, r, **kw): draw.rounded_rectangle(box(b), radius=width(r), **kw)

def main():
    subprocess.run(['povray', f'+L{HERE}', f'+I{HERE / "pipe.pov"}', f'+O{HERE / "pipe.png"}', '+W1024', '+H1024', '+FN', '+UA', '+A0.1', '-D', '-GR', '-GA', '-GS', '-GW'], check=True, stdout=subprocess.DEVNULL)
    # All drawing is done at 2x for smooth small-size results.
    bg = layer(); d = ImageDraw.Draw(bg)
    for y in range(N):
        t=y/(N-1); c=tuple(round(a*(1-t)+b*t) for a,b in zip((35,47,59),(8,13,20)))
        d.line((0,y,N,y), fill=(*c,255))
    mask=Image.new('L',(N,N)); rounded(ImageDraw.Draw(mask),(32,32,992,992),205,fill=255); bg.putalpha(mask)
    # Place the isolated pipe behind the chart enclosure.
    pipe=Image.open(HERE/'pipe.png').convert('RGBA'); bounds=pipe.getchannel('A').getbbox()
    if not bounds: raise RuntimeError('POV-Ray produced an empty pipe')
    pipe=pipe.crop(bounds); pipe=pipe.resize((width(335), round(pipe.height * width(335) / pipe.width)), Image.Resampling.LANCZOS)
    pipe_layer=layer(); pipe_layer.alpha_composite(pipe,(width(73),width(496)-pipe.height//2))
    pipe_layer.resize((1024,1024),Image.Resampling.LANCZOS).save(HERE/'01-pipe.png')
    # The separate plot artwork is useful when rebuilding in Icon Composer.
    plot=layer(); p=ImageDraw.Draw(plot)
    for x in (570,650,730,810,890): p.line((width(x),width(363),width(x),width(688)),fill=(125,143,158,48),width=width(2))
    for y in (390,465,540,615,690): p.line((width(550),width(y),width(904),width(y)),fill=(125,143,158,48),width=width(2))
    p.line([box((550,350)),box((550,697)),box((900,697))],fill=(150,161,172,205),width=width(8),joint='curve')
    # Map the chart into the measured concept box.
    sx, sy = 544/464, 441/418
    def align_box(im):
        return im.transform((N,N), Image.Transform.AFFINE, (1/sx,0,width(484)-width(406)/sx,0,1/sy,width(313)-width(279)/sy), Image.Resampling.BICUBIC)
    plot=align_box(plot)
    plot.resize((1024,1024),Image.Resampling.LANCZOS).save(HERE/'02-chart.png')

    # Render a rounded emissive tube as a separate 3D layer. The camera is
    # orthographic and aligned to the 1024px compositing canvas.
    curve_scene = HERE/'plot.pov'
    subprocess.run(['povray', f'+L{HERE}', f'+I{curve_scene}', f'+O{HERE / "04-plot-3d.png"}', '+W1024', '+H1024', '+FN', '+UA', '+A0.05', '-D', '-GR', '-GA', '-GS', '-GW'], check=True, stdout=subprocess.DEVNULL)
    molten=Image.open(HERE/'04-plot-3d.png').convert('RGBA').resize((N,N),Image.Resampling.LANCZOS)
    # Bloom is an image-space approximation; it is not emitted illumination.
    for colour, blur, opacity in [((220,40,0),28,105), ((255,105,0),12,155)]:
        alpha=molten.getchannel('A').filter(ImageFilter.GaussianBlur(width(blur))).point(lambda a: a*opacity//255)
        bloom=Image.new('RGBA',(N,N),(*colour,0)); bloom.putalpha(alpha); plot.alpha_composite(bloom)
    # Render the pipe and curve in the same perspective scene. Project each
    # curve coordinate into a plane just behind the pipe's visible surface;
    # the actual pipe can then occlude its first portion and reflect the tube.
    from math import tan, radians
    raw_scale = 335 / (bounds[2]-bounds[0])
    top = 496 - (bounds[3]-bounds[1])*raw_scale/2
    camera_depth = 16.4  # camera at z=-16; trace plane at z=0.4
    view_size = 2*camera_depth*tan(radians(70)/2)
    plot_scale = view_size / (raw_scale * 1024)
    plot_offset_x = 3 + ((bounds[0]-73/raw_scale)/1024-0.5)*view_size
    plot_offset_y = (0.5-(bounds[1]+(1024-top)/raw_scale)/1024)*view_size
    shared_scene=HERE/'shared-generated.pov'
    with shared_scene.open('w') as scene:
        scene.write('#include "pipe.pov"\n#include "chart.inc"\n')
        scene.write(f'ChartSweep({plot_scale:.12g}, <{plot_offset_x:.12g},{plot_offset_y:.12g},0.4>, 0.01, 0.8)\n')
    subprocess.run(['povray', f'+L{HERE}', f'+I{shared_scene}', f'+O{HERE / "shared-render.png"}', '+W1024', '+H1024', '+FN', '+UA', '+A0.05', '-D', '-GR', '-GA', '-GS', '-GW'], check=True, stdout=subprocess.DEVNULL)
    shared=Image.open(HERE/'shared-render.png').convert('RGBA')
    # Map the shared scene using the same camera crop as the original pipe.
    shared=shared.transform((N,N), Image.Transform.AFFINE,
        (1/(S*raw_scale),0,bounds[0]-73/raw_scale,0,1/(S*raw_scale),bounds[1]-top/raw_scale), Image.Resampling.BICUBIC)
    shared.resize((1024,1024),Image.Resampling.LANCZOS).save(HERE/'05-shared-scene.png')
    plot.alpha_composite(shared)
    # A graphic glass treatment is a static preview, not native Liquid Glass.
    glass=layer(); g=ImageDraw.Draw(glass)
    rounded(g,(484,313,948,731),27,fill=(125,165,185,22),outline=(217,236,244,150),width=width(5))
    rounded(g,(494,323,938,721),20,outline=(255,255,255,80),width=width(3))
    g.line([box((507,326)),box((921,326))],fill=(255,255,255,160),width=width(3))
    glass=align_box(glass)
    glass.resize((1024,1024),Image.Resampling.LANCZOS).save(HERE/'03-glass-preview.png')
    # Box body goes behind the chart; highlights appear in front.
    bg.alpha_composite(plot); bg.alpha_composite(glass)
    final=bg.resize((1024,1024),Image.Resampling.LANCZOS); final.save(HERE/'PipePlot-preview.png')
    iconset=HERE/'PipePlot.iconset'; iconset.mkdir(exist_ok=True)
    for logical in (16,32,128,256,512):
        for scale in (1,2):
            size=logical*scale; name=f'icon_{logical}x{logical}'+('@2x' if scale==2 else '')+'.png'
            final.resize((size,size),Image.Resampling.LANCZOS).save(iconset/name)
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(HERE/'PipePlot.icns')],check=True)
    print('Built PipePlot-preview.png and PipePlot.icns')

if __name__ == '__main__': main()
