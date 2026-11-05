"""Render the saved app icon without modifying the Blender source file."""
import argparse
import hashlib
from pathlib import Path
import sys

import bpy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scene', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    source = args.scene.resolve()
    output = args.output.resolve()
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.open_mainfile(filepath=str(source))
    scene = bpy.context.scene
    scene.frame_set(1)
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 256
    scene.cycles.use_denoising = True
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    backdrop = bpy.data.objects['Native macOS background preview']
    backdrop.visible_camera = True
    scene.render.filepath = str(output / 'preview.png')
    bpy.ops.render.render(write_still=True)
    backdrop.visible_camera = False
    scene.render.filepath = str(output / '02-Artwork.png')
    bpy.ops.render.render(write_still=True)
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original, 'Blender source changed during rendering'
    print(f'Icon renders written to {output}. Source scene unchanged.', flush=True)


if __name__ == '__main__':
    main()
