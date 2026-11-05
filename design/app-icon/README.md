# App icon source

Open `teleport-icon.blend` in Blender for the default graphite icon. The other
palettes are in `variants/purple.blend`, `variants/teal.blend`, and
`variants/coral.blend`. The scenes were saved with Blender 5.2.3 LTS.
Background images are packed into each file, so the scenes can be opened from
a fresh checkout without the original author's local files.

The camera, particle layout, trails, lights, and portal are editable. Use the
camera view to compose the icon and render with F12. Particle trails and glow
objects are parented to their particle. After rotating a particle, check its
trail direction and the camera-facing glow plane.

The native app icon is built from `teleport/Teleport.icon`. Its two layers are
the graphite gradient and transparent Blender artwork. The four flattened
palettes in `teleport/Resources/AppIcon*.png` supply the Settings previews and
alternate Dock icons. Graphite is the bundled default; a saved alternate choice
changes the running app's Dock and app-switcher icon. Finder and Spotlight use
the bundled graphite icon.

## Rendering

From the repository root, render a scene without saving changes to it:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --threads 8 --python-exit-code 1 \
  --python design/app-icon/render.py -- \
  --scene design/app-icon/teleport-icon.blend --output build/icon-render
```

This writes `preview.png` and `02-Artwork.png`. The first includes the packed
native background; the second hides it from the camera while retaining it for
glass transmission and reflections. CPU rendering avoids the Metal crashes
seen while developing these scenes. The script preserves the saved geometry,
materials, motion blur, and camera settings.

For a graphite artwork update, copy `02-Artwork.png` into
`teleport/Teleport.icon/Assets/02-Artwork.png`, open `teleport/Teleport.icon`
in Xcode's Icon Composer, and export the macOS Default rendition at 1024 × 1024
to `teleport/Resources/AppIconGraphite.png`. When changing the background,
update `01-Gradient.png` and the packed native background in Blender together,
so the exported icon and glass backdrop match. Alternate scenes export to their
corresponding `AppIconPurple.png`, `AppIconGreenBlue.png`, or `AppIconOrange.png`.
Keep flattened exports at full size. `AppIconStore` adds macOS padding when
applying an alternate Dock icon.
